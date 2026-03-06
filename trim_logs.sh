#!/usr/bin/env bash
# =============================================================================
# trim_logs.sh — Deep system-wide log trimmer
# Scans everywhere including /var/www and /home.
# A file is processed if:
#   - Its extension is a known log extension (.log, .err, .out, etc.)  OR
#   - Its filename (stem) is a known log name (error_log, access_log, etc.)
# Source code files (.php, .scss, .js, .po, etc.) are always skipped.
#
# Pipeline per matched file:
#   1. Remove ALL duplicate lines (first occurrence kept, order preserved)
#   2. Collapse consecutive repeated lines (uniq)
#   3. Keep only the last 1 MB
# =============================================================================

MAX_BYTES=$((1 * 1024 * 1024))   # 1 MB

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
    letsencrypt lastlog faillog wtwtmp btmp
    php_error php_errors
    stdout stderr output combined
)

# ---------- filename must contain one of these words (case-insensitive) ------
# Only used when the file has NO extension (bare filename check)
LOG_KEYWORDS=(
    error_log access_log debug_log
)

# ---------- extensions that are NEVER log files (source / data / media) ------
SKIP_EXTENSIONS=(
    # web source
    php php5 php7 php8 phtml
    js jsx ts tsx mjs cjs
    css scss sass less styl
    html htm xhtml
    twig blade smarty
    # data & config
    xml json yaml yml toml ini cfg conf env
    sql db sqlite sqlite3
    # translation / docs
    po pot mo
    txt md rst tex
    # archives
    gz bz2 xz zip zst 7z tar rar
    # binary / compiled
    bin so a o ko exe rpm deb
    # media
    jpg jpeg png gif ico svg webp mp3 mp4 avi mkv
    # misc
    pid sock lock bak bk swp tmp
    # WordPress/PHP specific
    neon phar map min
)

# ---------- dirs to skip entirely (databases, pseudo-fs, virtfs) -------------
SKIP_DIRS=(
    /var/lib/mysql
    /var/lib/mariadb
    /var/lib/postgresql
    /var/lib/mongodb
    /var/lib/redis
    /var/lib/docker
    /proc
    /sys
    /dev
    /run
    /snap
    /boot
    /lost+found
    /media
    /cdrom
    /usr
    /etc
    /home/virtfs        # cPanel virtual filesystem — contains OS/Python source mounts
)

# ---------- counters & flags -------------------------------------------------
TRIMMED=0
DEDUPED=0
SKIPPED=0
ERRORS=0
DRY_RUN=false
VERBOSE=false
DEBUG=false

# ---------- helpers ----------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Scans the entire system (including /var/www and /home) for log files.
A file qualifies if its extension is a known log extension, or its
filename matches a known log name. Source code files are always skipped.

Pipeline:
  1. Remove all duplicate lines (first occurrence wins)
  2. Collapse consecutive repeated lines
  3. Trim to last 1 MB

Options:
  -d, --dry-run   Preview without modifying any files
  -v, --verbose   Show every file checked including skips
      --debug     Print first 30 files find sees, then exit
  -h, --help      Show this help
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

# True if $1 is in the remaining args
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

# Get lowercase extension of a filename (empty string if none)
get_ext() {
    local base="$1"
    local ext="${base##*.}"
    [[ "$base" == "$ext" ]] && { echo ""; return; }   # no dot → no extension
    echo "${ext,,}"
}

# Get the stem (filename without final extension), lowercased
get_stem() {
    local base="$1"
    local ext="${base##*.}"
    [[ "$base" == "$ext" ]] && { echo "${base,,}"; return; }
    echo "${base%.*}" | tr '[:upper:]' '[:lower:]'
}

is_text_file() {
    if command -v file >/dev/null 2>&1; then
        file -b --mime-type "$1" 2>/dev/null | grep -q '^text/' && return 0
        return 1
    else
        # fallback: null bytes = binary
        grep -qP '\x00' "$1" 2>/dev/null && return 1
        return 0
    fi
}

# ── Master gate ───────────────────────────────────────────────────────────────
# A file passes if:
#   1. Not in a skip dir
#   2. Not a skip extension
#   3. Is plain text
#   4. Has a log extension  OR  has a log filename/stem
should_process() {
    local fp="$1"
    local base ext stem
    base=$(basename "$fp")
    ext=$(get_ext "$base")
    stem=$(get_stem "$base")

    # Rule 1: skip protected dirs
    if in_skip_dir "$fp"; then
        $VERBOSE && log_info "SKIP [protected dir]   $fp"
        (( SKIPPED++ )); return 1
    fi

    # Rule 2: skip source-code / data extensions immediately
    if [[ -n "$ext" ]] && in_array "$ext" "${SKIP_EXTENSIONS[@]}"; then
        $VERBOSE && log_info "SKIP [source ext .$ext]  $fp"
        (( SKIPPED++ )); return 1
    fi

    # Rule 3: must be plain text (skip compiled/binary files with no extension)
    if ! is_text_file "$fp"; then
        $VERBOSE && log_info "SKIP [binary]          $fp"
        (( SKIPPED++ )); return 1
    fi

    # Rule 4a: known log extension
    if [[ -n "$ext" ]] && in_array "$ext" "${LOG_EXTENSIONS[@]}"; then
        return 0
    fi

    # Rule 4b: exact log filename (no extension, e.g. "error_log", "syslog")
    if [[ -z "$ext" ]] && in_array "$stem" "${LOG_FILENAMES[@]}"; then
        return 0
    fi

    # Rule 4c: bare filename contains _log suffix/prefix AND has no extension
    # e.g. "error_log", "php_error_log" — but NOT "_log.py", "web_log.py" etc.
    if [[ -z "$ext" ]] && echo "$stem" | grep -qiE '^(.*_log|log_.*)$'; then
        return 0
    fi

    $VERBOSE && log_info "SKIP [not a log]       $fp"
    (( SKIPPED++ )); return 1
}

# ── Core pipeline ─────────────────────────────────────────────────────────────
process_file() {
    local fp="$1"
    local orig_size
    orig_size=$(stat -c%s "$fp" 2>/dev/null || echo 0)

    if (( orig_size == 0 )); then
        $VERBOSE && log_info "SKIP [empty]           $fp"
        (( SKIPPED++ )); return
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

    local changed=false actions=()
    (( orig_size != dedup_size )) && { actions+=("deduped $(human_size "$orig_size")→$(human_size "$dedup_size")"); changed=true; (( DEDUPED++ )); }
    (( dedup_size > MAX_BYTES  )) && { actions+=("trimmed→$(human_size "$final_size")"); changed=true; }

    if $changed; then
        log_info "$(printf '%-65s' "$fp")  [$(IFS=', '; echo "${actions[*]}")]"
        (( TRIMMED++ ))
    else
        $VERBOSE && log_info "OK  $fp  ($(human_size "$orig_size"))"
    fi
}

# ---------- arg parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run) DRY_RUN=true  ;;
        -v|--verbose) VERBOSE=true  ;;
        --debug)      DEBUG=true    ;;
        -h|--help)    usage          ;;
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

# ---------- main scan --------------------------------------------------------
log_info "Starting deep system-wide log scan (includes /var/www and /home)..."
log_info "Matches: known log extensions (.log, .err, .out ...) + known log filenames (error_log, syslog ...)"
log_info "Pipeline: dedup all lines  ->  collapse consecutive  ->  trim to 1MB"
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

# ---------- summary ----------------------------------------------------------
echo ""
echo "======================================================"
echo "  Scan complete"
echo "  Files modified      : $TRIMMED"
echo "  Files deduplicated  : $DEDUPED"
echo "  Files skipped       : $SKIPPED"
echo "  Errors              : $ERRORS"
$DRY_RUN && echo "  (DRY-RUN — nothing was written)"
echo "======================================================"
