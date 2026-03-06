#!/usr/bin/env bash
# =============================================================================
# trim_logs.sh — Deep system-wide log trimmer (cron-optimised)
#
# On first run: processes every log file found.
# On subsequent runs: skips any file whose mtime+size hasn't changed since
#   it was last processed — making cron re-runs very fast.
#
# Pipeline per changed file:
#   1. Remove ALL duplicate lines (first occurrence kept, order preserved)
#   2. Collapse consecutive repeated lines (uniq)
#   3. Keep only the last 1 MB
#
# Cache stored in: /var/cache/trim_logs/state.db  (tab-separated)
# Format:  <mtime>TAB<size>TAB<filepath>
# =============================================================================

MAX_BYTES=$((1 * 1024 * 1024))          # 1 MB
STATE_DIR="/var/cache/trim_logs"
STATE_FILE="${STATE_DIR}/state.db"
STATE_TMP="${STATE_DIR}/state.tmp.$$"   # atomic write target

# ---------- extensions that ARE log files ------------------------------------
LOG_EXTENSIONS=(
    log log.1 log.2 log.3 log.4 log.5
    err error errors
    out
    warn warning
    debug trace info
    access combined
    stdout stderr
)

# ---------- exact filenames (no extension) that are log files ----------------
LOG_FILENAMES=(
    error_log access_log debug_log warn_log trace_log
    syslog messages auth daemon kern mail cron dmesg
    letsencrypt lastlog faillog btmp
    php_error php_errors
    stdout stderr output combined
)

# ---------- extensions that are NEVER log files ------------------------------
SKIP_EXTENSIONS=(
    php php5 php7 php8 phtml
    js jsx ts tsx mjs cjs
    css scss sass less styl
    html htm xhtml
    twig blade smarty
    xml json yaml yml toml ini cfg conf env
    sql db sqlite sqlite3
    po pot mo
    txt md rst tex
    gz bz2 xz zip zst 7z tar rar
    bin so a o ko exe rpm deb
    jpg jpeg png gif ico svg webp mp3 mp4 avi mkv
    pid sock lock bak bk swp tmp
    neon phar map min
)

# ---------- dirs to skip entirely --------------------------------------------
SKIP_DIRS=(
    /var/lib/mysql
    /var/lib/mariadb
    /var/lib/postgresql
    /var/lib/mongodb
    /var/lib/redis
    /var/lib/docker
    /proc /sys /dev /run
    /snap /boot /lost+found /media /cdrom
    /usr /etc
    /home/virtfs
    "${STATE_DIR}"          # never process our own cache
)

# ---------- counters & flags -------------------------------------------------
TRIMMED=0
DEDUPED=0
SKIPPED=0
UNCHANGED=0
ERRORS=0
DRY_RUN=false
VERBOSE=false
DEBUG=false
RESET_CACHE=false

# ---------- helpers ----------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Scans the entire system for log files and trims each one:
  1. Remove all duplicate lines
  2. Collapse consecutive repeated lines
  3. Trim to last 1 MB

Cron-optimised: files unchanged since last run are skipped instantly
using a mtime+size cache stored at: ${STATE_FILE}

Options:
  -d, --dry-run      Preview without modifying any files
  -v, --verbose      Show every file checked including skips/unchanged
      --reset-cache  Force reprocess all files (ignore cache)
      --debug        Print first 30 files find sees, then exit
  -h, --help         Show this help
EOF
    exit 0
}

log_info() { echo "[INFO]  $*"; }
log_warn() { echo "[WARN]  $*"; }
log_err()  { echo "[ERROR] $*"; }

human_size() {
    local b="$1"
    if   (( b >= 1073741824 )); then printf '%dG' $(( b / 1073741824 ))
    elif (( b >= 1048576 ));    then printf '%dM' $(( b / 1048576 ))
    elif (( b >= 1024 ));       then printf '%dK' $(( b / 1024 ))
    else printf '%dB' "$b"
    fi
}

in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

in_skip_dir() {
    local p="$1" d
    for d in "${SKIP_DIRS[@]}"; do
        case "$p" in "$d"|"$d"/*) return 0 ;; esac
    done
    return 1
}

get_ext() {
    local base="$1" ext
    ext="${base##*.}"
    [[ "$base" == "$ext" ]] && { echo ""; return; }
    echo "${ext,,}"
}

get_stem() {
    local base="$1" ext
    ext="${base##*.}"
    [[ "$base" == "$ext" ]] && { echo "${base,,}"; return; }
    echo "${base%.*}" | tr '[:upper:]' '[:lower:]'
}

is_text_file() {
    if command -v file >/dev/null 2>&1; then
        file -b --mime-type "$1" 2>/dev/null | grep -q '^text/' && return 0
        return 1
    else
        grep -qP '\x00' "$1" 2>/dev/null && return 1
        return 0
    fi
}

# ── Cache helpers ─────────────────────────────────────────────────────────────
# Returns "<mtime> <size>" for a file
file_signature() {
    stat -c '%Y %s' "$1" 2>/dev/null || echo "0 0"
}

# Load state.db into associative array  cache[filepath]="mtime size"
declare -A CACHE

load_cache() {
    [[ -f "$STATE_FILE" ]] || return
    while IFS=$'\t' read -r mtime size fp; do
        [[ -n "$fp" ]] && CACHE["$fp"]="${mtime} ${size}"
    done < "$STATE_FILE"
    log_info "Cache loaded: ${#CACHE[@]} entries from ${STATE_FILE}"
}

# Write updated cache atomically
save_cache() {
    $DRY_RUN && return   # never mutate cache in dry-run
    mkdir -p "$STATE_DIR"
    # Merge: start from old cache, overlay new entries written during this run
    # NEW_CACHE associative array was populated during processing
    {
        # Keep old entries for files we didn't touch this run
        for fp in "${!CACHE[@]}"; do
            [[ -z "${NEW_CACHE[$fp]+x}" ]] && {
                local old="${CACHE[$fp]}"
                printf '%s\t%s\t%s\n' "${old% *}" "${old#* }" "$fp"
            }
        done
        # Write new/updated entries
        for fp in "${!NEW_CACHE[@]}"; do
            local sig="${NEW_CACHE[$fp]}"
            printf '%s\t%s\t%s\n' "${sig% *}" "${sig#* }" "$fp"
        done
    } | sort -t$'\t' -k3 > "$STATE_TMP" && mv "$STATE_TMP" "$STATE_FILE"
}

declare -A NEW_CACHE

# Record the post-process signature of a file into NEW_CACHE
record_signature() {
    local fp="$1"
    local sig
    sig=$(file_signature "$fp")
    NEW_CACHE["$fp"]="$sig"
}

# True if the file is unchanged since last run
is_unchanged() {
    local fp="$1"
    local cached="${CACHE[$fp]:-}"
    [[ -z "$cached" ]] && return 1           # not in cache → must process
    local current
    current=$(file_signature "$fp")
    [[ "$cached" == "$current" ]] && return 0   # same mtime+size → skip
    return 1
}

# ── Master gate ───────────────────────────────────────────────────────────────
should_process() {
    local fp="$1"
    local base ext stem
    base=$(basename "$fp")
    ext=$(get_ext "$base")
    stem=$(get_stem "$base")

    in_skip_dir "$fp" && {
        $VERBOSE && log_info "SKIP [protected dir]      $fp"
        (( SKIPPED++ )); return 1
    }

    if [[ -n "$ext" ]] && in_array "$ext" "${SKIP_EXTENSIONS[@]}"; then
        $VERBOSE && log_info "SKIP [source ext .$ext]   $fp"
        (( SKIPPED++ )); return 1
    fi

    is_text_file "$fp" || {
        $VERBOSE && log_info "SKIP [binary]             $fp"
        (( SKIPPED++ )); return 1
    }

    # Check cache BEFORE the expensive is_text_file already passed — fast path
    if ! $RESET_CACHE && is_unchanged "$fp"; then
        $VERBOSE && log_info "SKIP [unchanged]          $fp"
        (( UNCHANGED++ )); return 1
    fi

    [[ -n "$ext" ]] && in_array "$ext" "${LOG_EXTENSIONS[@]}" && return 0
    [[ -z "$ext" ]] && in_array "$stem" "${LOG_FILENAMES[@]}" && return 0
    [[ -z "$ext" ]] && echo "$stem" | grep -qiE '^(.*_log|log_.*)$' && return 0

    $VERBOSE && log_info "SKIP [not a log]          $fp"
    (( SKIPPED++ )); return 1
}

# ── Core pipeline ─────────────────────────────────────────────────────────────
process_file() {
    local fp="$1"
    local orig_size
    orig_size=$(stat -c%s "$fp" 2>/dev/null || echo 0)

    if (( orig_size == 0 )); then
        $VERBOSE && log_info "SKIP [empty]              $fp"
        (( SKIPPED++ ))
        record_signature "$fp"
        return
    fi

    if $DRY_RUN; then
        local tl dl
        tl=$(wc -l < "$fp" 2>/dev/null || echo 0)
        dl=$(awk '!seen[$0]++' "$fp" 2>/dev/null | uniq | wc -l 2>/dev/null || echo 0)
        log_info "[DRY-RUN] $fp  ($(human_size "$orig_size"), ~$(( tl - dl )) dup lines)"
        (( TRIMMED++ )); return
    fi

    local tmp_a tmp_b
    tmp_a=$(mktemp /tmp/trimlog_a.XXXXXX)
    tmp_b=$(mktemp /tmp/trimlog_b.XXXXXX)

    # Step 1+2: global dedup then consecutive collapse
    if ! awk '!seen[$0]++' "$fp" 2>/dev/null | uniq > "$tmp_a" 2>/dev/null; then
        log_warn "Dedup failed: $fp"
        rm -f "$tmp_a" "$tmp_b"; (( ERRORS++ )); return
    fi

    local dedup_size
    dedup_size=$(stat -c%s "$tmp_a" 2>/dev/null || echo 0)

    # Step 3: keep last 1 MB
    if ! tail -c "$MAX_BYTES" "$tmp_a" > "$tmp_b" 2>/dev/null; then
        log_warn "Tail failed: $fp"
        rm -f "$tmp_a" "$tmp_b"; (( ERRORS++ )); return
    fi

    local final_size
    final_size=$(stat -c%s "$tmp_b" 2>/dev/null || echo 0)

    chmod --reference="$fp" "$tmp_b" 2>/dev/null || true
    chown --reference="$fp" "$tmp_b" 2>/dev/null || true

    if ! mv "$tmp_b" "$fp" 2>/dev/null; then
        log_warn "Replace failed (permission?): $fp"
        rm -f "$tmp_a" "$tmp_b"; (( ERRORS++ )); return
    fi
    rm -f "$tmp_a"

    # Record new signature AFTER writing (so next run sees the trimmed state)
    record_signature "$fp"

    local changed=false actions=()
    (( orig_size != dedup_size )) && { actions+=("deduped $(human_size "$orig_size")→$(human_size "$dedup_size")"); changed=true; (( DEDUPED++ )); }
    (( dedup_size > MAX_BYTES  )) && { actions+=("trimmed→$(human_size "$final_size")"); changed=true; }

    if $changed; then
        log_info "$(printf '%-65s' "$fp")  [$(IFS=', '; echo "${actions[*]}")]"
        (( TRIMMED++ ))
    else
        # File was in scope (new to cache) but already clean
        $VERBOSE && log_info "OK (clean)                $fp  ($(human_size "$orig_size"))"
    fi
}

# ---------- arg parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)    DRY_RUN=true     ;;
        -v|--verbose)    VERBOSE=true     ;;
        --reset-cache)   RESET_CACHE=true ;;
        --debug)         DEBUG=true       ;;
        -h|--help)       usage             ;;
        *) log_err "Unknown option: $1"; usage ;;
    esac
    shift
done

# ---------- privilege check --------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_warn "Not running as root — many files will be unreadable."
    log_warn "Re-run with: sudo $0"
    echo ""
fi

# ---------- debug mode -------------------------------------------------------
if $DEBUG; then
    echo "=== DEBUG: First 30 files find sees ==="
    find / \
        \( -path "/var/lib/mysql" -o -path "/var/lib/mariadb" -o \
           -path "/var/lib/postgresql" -o -path "/var/lib/mongodb" -o \
           -path "/var/lib/redis" -o -path "/var/lib/docker" -o \
           -path "/proc" -o -path "/sys" -o -path "/dev" -o \
           -path "/run" -o -path "/snap" -o -path "/boot" -o \
           -path "/lost+found" -o -path "/media" -o \
           -path "/home/virtfs" -o \
           -path "/cdrom" -o -path "/mnt" \) -prune \
        -o -type f -print 2>/dev/null | head -30
    echo "=== end debug ==="
    exit 0
fi

# ---------- init cache -------------------------------------------------------
mkdir -p "$STATE_DIR"
$RESET_CACHE && { log_info "--reset-cache: ignoring existing cache, all files will be reprocessed."; rm -f "$STATE_FILE"; }
load_cache

# ---------- main scan --------------------------------------------------------
log_info "Starting deep system-wide log scan (includes /var/www and /home)..."
log_info "Cache: ${STATE_FILE}"
$DRY_RUN && log_info "DRY-RUN — no files will be modified."
echo ""

while IFS= read -r -d '' fp; do
    should_process "$fp" || continue
    process_file "$fp"
done < <(
    find / \
        \( -path "/var/lib/mysql" -o -path "/var/lib/mariadb" -o \
           -path "/var/lib/postgresql" -o -path "/var/lib/mongodb" -o \
           -path "/var/lib/redis" -o -path "/var/lib/docker" -o \
           -path "/proc" -o -path "/sys" -o -path "/dev" -o \
           -path "/run" -o -path "/snap" -o -path "/boot" -o \
           -path "/lost+found" -o -path "/media" -o \
           -path "/home/virtfs" -o \
           -path "/cdrom" -o -path "/mnt" \) -prune \
        -o -type f -print0 2>/dev/null
)

# ---------- save cache & summary ---------------------------------------------
save_cache

echo ""
echo "======================================================"
echo "  Scan complete"
echo "  Files modified      : $TRIMMED"
echo "  Files deduplicated  : $DEDUPED"
echo "  Files unchanged     : $UNCHANGED  (skipped via cache)"
echo "  Files skipped       : $SKIPPED"
echo "  Errors              : $ERRORS"
$DRY_RUN && echo "  (DRY-RUN — nothing was written)"
echo "======================================================"
