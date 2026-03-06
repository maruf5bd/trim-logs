# trim-logs

A zero-dependency Bash script that performs a **deep system-wide log cleanup** on Linux servers. It scans the entire filesystem — including `/home`, `/var/www`, and all user directories — finds every log file, removes duplicate lines, and trims each file down to a maximum of **1 MB**.

Designed for shared hosting servers, VPS, and cPanel/WHM environments.

---

## What It Does

For every log file found on the system, the script runs a 3-step pipeline:

1. **Deduplicate** — removes every duplicate line anywhere in the file, keeping the first occurrence and preserving line order
2. **Collapse** — removes consecutive repeated lines (like `uniq`)
3. **Trim** — keeps only the last 1 MB of the cleaned content (most recent log entries)

---

## What It Scans

| Location | Behaviour |
|---|---|
| `/var/log/**` | ✅ Fully scanned |
| `/home/*/` | ✅ Scanned — `.log`, `error_log`, `access_log` etc. |
| `/var/www/**` | ✅ Scanned — log files only |
| `/tmp`, `/var/tmp` | ✅ Scanned |
| `/home/virtfs/` | ❌ Skipped — cPanel virtual FS (OS source mounts) |
| `/var/lib/mysql` | ❌ Skipped — MySQL/MariaDB data |
| `/proc`, `/sys`, `/dev` | ❌ Skipped — pseudo-filesystems |
| `/usr`, `/etc`, `/boot` | ❌ Skipped — system files |

---

## What Counts as a Log File

A file is processed if **any** of these match:

- **Extension** is a known log extension:
  `.log`, `.log.1`–`.log.5`, `.err`, `.error`, `.errors`, `.out`, `.warn`, `.warning`, `.debug`, `.trace`, `.info`, `.access`, `.combined`, `.stdout`, `.stderr`

- **Filename** (no extension) is a known log name:
  `error_log`, `access_log`, `debug_log`, `syslog`, `messages`, `auth`, `cron`, `dmesg`, `kern`, `mail`, `daemon`, `php_error`, `stdout`, `stderr`, etc.

- **Bare filename stem** ends or starts with `_log` / `log_` (e.g. `php_error_log`)

---

## What Is Always Skipped

**Source code & config extensions** — never touched regardless of filename:

`.php` `.py` `.rb` `.js` `.ts` `.css` `.scss` `.html` `.xml` `.json` `.yaml` `.conf` `.ini` `.env` `.po` `.pot` `.mo` `.md` `.txt` `.sql` `.db` `.sqlite` `.gz` `.zip` `.tar` `.bak` `.pid` `.lock` `.sock` and more.

**Protected directories:**

`/proc` `/sys` `/dev` `/run` `/usr` `/etc` `/boot` `/snap` `/home/virtfs` `/var/lib/mysql` `/var/lib/mariadb` `/var/lib/postgresql` `/var/lib/mongodb` `/var/lib/redis` `/var/lib/docker`

**Binary files** — detected via `file --mime-type`, never processed.

---

## Installation

```bash
# Download
wget https://raw.githubusercontent.com/YOUR_USERNAME/trim-logs/main/trim_logs.sh

# Make executable
chmod +x trim_logs.sh
```

---

## Usage

```bash
# Full run (recommended: run as root)
sudo bash trim_logs.sh

# Preview what would be changed — no files are modified
sudo bash trim_logs.sh --dry-run

# Show every file checked including skipped files
sudo bash trim_logs.sh --verbose

# Diagnose scanning — print first 30 files find sees, then exit
sudo bash trim_logs.sh --debug
```

### Options

| Flag | Description |
|---|---|
| `-d`, `--dry-run` | Preview mode — no files are modified |
| `-v`, `--verbose` | Print every file checked, including skips |
| `--debug` | Print the first 30 files `find` would return, then exit |
| `-h`, `--help` | Show help |

---

## Example Output

```
[INFO]  Starting deep system-wide log scan (includes /var/www and /home)...
[INFO]  Pipeline: dedup all lines  ->  collapse consecutive  ->  trim to 1MB

[INFO]  /var/log/nginx/access.log                   [deduped 14M→3M, trimmed→1M]
[INFO]  /var/log/syslog                             [deduped 8M→5M, trimmed→1M]
[INFO]  /home/user/logs/php.error.log               [deduped 512K→280K]
[INFO]  /home/user/public_html/error_log            [deduped 256K→242K]
[INFO]  /var/log/auth.log                           [deduped 2M→900K, trimmed→1M]

======================================================
  Scan complete
  Files modified      : 47
  Files deduplicated  : 47
  Files skipped       : 18423
  Errors              : 0
======================================================
```

---

## Automating with Cron

Run every Sunday at 2 AM:

```bash
crontab -e
```

Add:

```
0 2 * * 0 /bin/bash /root/trim_logs.sh >> /var/log/trim_logs.log 2>&1
```

---

## Requirements

- Bash 4+
- Standard GNU coreutils: `find`, `awk`, `tail`, `stat`, `mv`, `wc`
- `file` command (from `file` package) — used for binary detection; has a fallback if missing
- Root access recommended (`sudo`) for full system coverage

---

## Tested On

- CentOS 7 / 8
- AlmaLinux 8 / 9
- Rocky Linux 8 / 9
- Ubuntu 20.04 / 22.04
- cPanel / WHM servers

---

## License

MIT — free to use, modify, and distribute.
