#!/bin/bash
# Collect Benno MailArchiv monitoring signals as JSON for the Zabbix agent.
#
# Runs as a root cron job because the Zabbix agent user normally may not read
# the systemd journal, the archive repository or Benno's logs. The agent then
# only cat's the JSON this script writes (see benno-zabbix.conf).
#
# Design / safety:
#   - Dedicated root-owned state dir (not the shared agent dir): temp files are
#     created with mktemp inside it and atomically renamed, so a predictable
#     name cannot be pre-planted as a symlink for a privileged overwrite.
#   - A non-blocking flock makes the whole run single-instance, so an old slow
#     run cannot clobber newer status, and overlapping runs cannot race the mv.
#   - "ts" field + staleness read in benno-zabbix.conf: a stopped cron/script
#     surfaces as nodata instead of a frozen value.
#   - journal_ok / collector_ok flags carry an explicit UNKNOWN state: a failed
#     measurement is never published as a healthy zero, and never fakes age 0.
#   - last_ok_age uses the REAL timestamp of the last successful fetch, not the
#     current time.

set -u
# JSON needs a dot decimal separator and no locale/scientific number formatting.
# The cron inherits the system locale via pam_env (/etc/default/locale), so a
# German locale would otherwise make awk print e.g. "1,1e+11" -> invalid JSON.
export LC_ALL=C

# ---- CONFIG: adjust to your Benno installation (or set via the cron environment) ----
OUT="${BENNO_STATE_DIR:-/var/lib/benno-zabbix}"              # root-owned state dir (must match benno-zabbix.conf); created 0755 root:root
INBOX_DIR="${BENNO_INBOX_DIR:-/srv/benno/inbox}"             # Benno inbox (pending mails)
ARCHIVE_DIR="${BENNO_ARCHIVE_DIR:-/srv/benno/archive}"       # archive root (du target)
ARCHIVE_REPO_DIR="${BENNO_ARCHIVE_REPO_DIR:-/srv/benno/archive/repo}"  # where archived files live (file count)
POP3_ID="${BENNO_POP3_IDENT:-benno-pop3}"                    # syslog/systemd identifier of the fetch job
ARCHIVE_CACHE_MAX_AGE="${BENNO_ARCHIVE_CACHE_MAX_AGE:-21600}" # seconds between expensive du runs (default 6h)
FRESH_WINDOW="${BENNO_FRESH_WINDOW:-20 min}"                 # window for a recent successful fetch
DU_TIMEOUT="${BENNO_DU_TIMEOUT:-240}"                        # seconds cap for the archive scan (du+find)
IMPORT_LOG="${BENNO_IMPORT_LOG:-/var/log/benno/archive.log}" # Benno import/archive log (0640 benno:benno; root-readable, agent not)
IMPORT_ERR_WINDOW="${BENNO_IMPORT_ERR_WINDOW:-20 min}"      # window for counting recent import errors
IMPORT_ERR_LEVELS="${BENNO_IMPORT_ERR_LEVELS:-ERROR|FATAL|SEVERE}" # log4j levels (field 2) that count as an error
WEB_CERT_HOST="${BENNO_WEB_CERT_HOST:-$(hostname -f 2>/dev/null || echo localhost)}" # SNI/host for the web TLS cert expiry check
WEB_CERT_PORT="${BENNO_WEB_CERT_PORT:-443}"                 # local TLS port to read the web cert from
LICENSE_FILE="${BENNO_LICENSE_FILE:-/etc/benno/benno.lic}"  # Benno license file — only the Expires: date is read, never the key/licensee/domain
IMAPIMPORT_LOG="${BENNO_IMAPIMPORT_LOG:-/var/log/benno-imapimport.log}" # wrapper log of a benno-imapimport cron (e.g. the Kerio/IMAP import); absent -> not in use
INBOX_STUCK_HOURS="${BENNO_INBOX_STUCK_HOURS:-2}"           # count .err/.prc inbox files older than this many hours (stuck mail)
SYSTEMD_IGNORE="${BENNO_SYSTEMD_IGNORE:-}"                  # comma/space list of failed units to NOT count (e.g. a chkrootkit.service exit-code quirk); review before silencing a security unit
BACKUP_STAMP="${BENNO_BACKUP_STAMP:-}"                      # file whose mtime a successful backup updates (touch it at the end of your backup job, any tool); unset/missing -> backup_age=-1 and nothing alerts
# Error patterns in the fetch log that mean "this run failed" (extended regex, case-insensitive).
ERR_RE="${BENNO_ERR_RE:-Error\[|Too much login errors|Connection timed out|timed out|timeout|refused|cannot|unable|failed|abort}"
# -------------------------------------------------------------------------------------

now=$(date +%s)
STATUS="$OUT/benno_status.json"
AT="$OUT/benno_archive_total.json"
LOCK="$OUT/.lock"

# The state dir must exist and be root-owned; the installer creates it. If it is
# missing we cannot safely write anywhere, so bail loudly (cron routes to logger).
if [ ! -d "$OUT" ]; then
  echo "benno-zabbix: state dir $OUT missing (create it 0755 root:root)" >&2
  exit 3
fi

# Single-instance: skip if a previous run still holds the lock (prevents a slow
# run from clobbering newer status and prevents overlapping writers).
exec 9>"$LOCK" || { echo "benno-zabbix: cannot open lock $LOCK" >&2; exit 3; }
flock -n 9 || exit 0

# Write JSON atomically via a unique temp in the same (root-owned) dir.
write_json() {  # $1=target path, $2=json string
  local tmp
  tmp=$(mktemp "$OUT/.tmp.XXXXXX") || { echo "benno-zabbix: mktemp failed in $OUT" >&2; return 1; }
  if printf '%s\n' "$2" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"; return 1
}

# Load the previous last_ok_epoch so a journal outage can hold it instead of
# fabricating a healthy age.
prev_epoch=0
if [ -f "$STATUS" ]; then
  prev_epoch=$(sed -n 's/.*"last_ok_epoch":\([0-9]*\).*/\1/p' "$STATUS")
  prev_epoch=${prev_epoch:-0}
fi

# --- Is the journal readable right now? ---
# The system journal of the last few minutes is practically never empty. Empty
# output OR a non-zero exit => journal transiently unreadable (rotation/lock),
# which is NOT the same as "no fetch happened".
jraw=$(journalctl --since "-$FRESH_WINDOW" -o short-unix 2>/dev/null); jrc=$?
jlines=$(printf '%s' "$jraw" | grep -c .)
journal_ok=1
if [ "$jrc" -ne 0 ] || [ "$jlines" -eq 0 ]; then journal_ok=0; fi

# --- POP3/IMAP fetch freshness (real event time) ---
# last_ok_epoch = unix time of the most recent "Fetched N files" line (any count;
# an empty poll is still a healthy run). age is derived from that REAL time.
#   journal unreadable      -> epoch=prev, age=-1  (UNKNOWN; journal_ok trigger fires)
#   no Fetched in 48h        -> epoch=0,    age=large (real pickup outage; age trigger fires)
#   otherwise                -> epoch=real, age=now-epoch
recent_err=0
if [ "$journal_ok" -eq 0 ]; then
  last=$prev_epoch; age=-1
else
  recent_err=$(journalctl -t "$POP3_ID" --since "-$FRESH_WINDOW" 2>/dev/null | grep -ciE "$ERR_RE")
  last_fetch=$(journalctl -t "$POP3_ID" --since "-48 hours" -o short-unix 2>/dev/null | grep -F "Fetched" | tail -1 | cut -d. -f1)
  if [ -n "${last_fetch:-}" ]; then last=$last_fetch; age=$(( now - last )); else last=0; age=999999; fi
fi

# --- Inbox queue (regular files at depth 1). Missing dir = UNKNOWN, not 0. ---
collector_ok=1
if [ -d "$INBOX_DIR" ]; then
  inbox=$(find "$INBOX_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
else
  inbox=-1; collector_ok=0
fi

# --- Stuck inbox files: .err (archiving failed) and .prc (stuck in processing),
# older than INBOX_STUCK_HOURS hours, to separate hung mail from normal in-flight
# .eml. -1 when the inbox dir is missing. ---
inbox_err_aged=-1; inbox_prc_aged=-1
if [ -d "$INBOX_DIR" ]; then
  inbox_err_aged=$(find "$INBOX_DIR" -maxdepth 1 -type f -name '*.err' -mmin +$((INBOX_STUCK_HOURS*60)) 2>/dev/null | wc -l)
  inbox_prc_aged=$(find "$INBOX_DIR" -maxdepth 1 -type f -name '*.prc' -mmin +$((INBOX_STUCK_HOURS*60)) 2>/dev/null | wc -l)
fi

# --- Benno import-log errors (root reads the 0640 benno log; the agent gets only
# counts, never log content, so no customer mail metadata reaches Zabbix). log4j
# lines are "<ISO-8601>,<ms> <LEVEL>  <msg>"; ISO timestamps sort lexically, so the
# window is a string compare (no per-line date()). import_err_20m = -1 means the log
# was missing/unreadable -> the check is BROKEN, which is not the same as "0 errors".
import_err_20m=-1; import_err_last_epoch=0
if [ -r "$IMPORT_LOG" ]; then
  err_cut=$(date -d "-$IMPORT_ERR_WINDOW" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
  ie=$(awk -v cut="$err_cut" -v lv="$IMPORT_ERR_LEVELS" '
    $2 ~ ("^(" lv ")$") { t=$1; sub(/,.*/,"",t); if (t>=cut) c++; if (t>last) last=t }
    END { printf "%d|%s", c+0, last }' "$IMPORT_LOG")
  import_err_20m=${ie%%|*}
  ie_lastts=${ie#*|}
  [ -n "$ie_lastts" ] && import_err_last_epoch=$(date -d "$ie_lastts" +%s 2>/dev/null || echo 0)
fi

# --- Web TLS certificate: days until expiry (-1 if unreadable). Read locally on
# 443, so a cert-renewal failure shows here BEFORE the browser-facing nodata trigger.
web_cert_days=-1
if command -v openssl >/dev/null 2>&1; then
  cert_end=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:"$WEB_CERT_PORT" -servername "$WEB_CERT_HOST" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$cert_end" ]; then
    cert_exp=$(date -d "$cert_end" +%s 2>/dev/null)
    [ -n "$cert_exp" ] && web_cert_days=$(( (cert_exp - now) / 86400 ))
  fi
fi

# --- NTP synchronisation (1 = synced, 0 = not). Correct time matters for a
# revision-safe archive; where a restrictive egress firewall is used, allow outbound UDP 123. ---
ntp_synced=0
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && ntp_synced=1

# --- Postfix mail queue depth (-1 if postfix tools are absent). ---
postfix_queue=-1
if command -v mailq >/dev/null 2>&1; then
  postfix_queue=$(mailq 2>/dev/null | grep -cE '^[0-9A-F]{8,}')
  [ -z "$postfix_queue" ] && postfix_queue=-1
fi

# --- systemd failed-unit count (catch-all). A latent failure surfaces here even
# when nothing else alerts yet. Count only, no unit names; run `systemctl --failed`
# on the host to see which. BENNO_SYSTEMD_IGNORE drops known-cosmetic units (e.g.
# a chkrootkit.service exit-code quirk) from the count. ---
systemd_failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk -v ign="$SYSTEMD_IGNORE" '
  BEGIN { n = split(ign, a, /[, ]+/); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1 }
  $1 ~ /\./ && !($1 in skip) { c++ }
  END { print c + 0 }')

# --- Benno license days until expiry (-1 if no license file or no Expires field,
# e.g. a community/perpetual install). Reads ONLY the Expires: date, never the key,
# licensee or mail domain, so nothing identifying leaves the host. ---
license_days=-1
if [ -r "$LICENSE_FILE" ]; then
  lic_exp=$(grep -iE '^Expires:' "$LICENSE_FILE" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' ')
  if [ -n "$lic_exp" ]; then
    lic_epoch=$(date -d "$lic_exp" +%s 2>/dev/null)
    [ -n "$lic_epoch" ] && license_days=$(( (lic_epoch - now) / 86400 ))
  fi
fi

# --- benno-imapimport wrapper (IMAP/Kerio import via a cron that appends [OK]/
# [ERROR]/[SKIP] to a log; see the benno-import.sh pattern). On installs that do
# not use it the log is absent -> both values stay -1 and nothing alerts.
#   imapimport_last: 1 = last run OK, 0 = last run ERROR, 2 = SKIP (lock held),
#                    -1 = no log / no outcome yet.
#   imapimport_age : seconds since the log was last written (-1 = no log). ---
imapimport_last=-1; imapimport_age=-1
if [ -r "$IMAPIMPORT_LOG" ]; then
  imapimport_age=$(( now - $(stat -c %Y "$IMAPIMPORT_LOG" 2>/dev/null || echo "$now") ))
  case "$(grep -oE '\[(OK|ERROR|SKIP)\]' "$IMAPIMPORT_LOG" 2>/dev/null | tail -1)" in
    '[OK]')    imapimport_last=1 ;;
    '[ERROR]') imapimport_last=0 ;;
    '[SKIP]')  imapimport_last=2 ;;
  esac
fi

# --- Backup freshness (generic, backup-tool agnostic). BENNO_BACKUP_STAMP points
# at a file whose mtime a successful backup updates; the backup job touches it on
# success (PBS, Borg, restic, rsync, tar -- whatever). Unset/missing -> -1 and
# nothing alerts, so this stays silent until an operator wires a backup in. ---
backup_age=-1
if [ -n "$BACKUP_STAMP" ] && [ -e "$BACKUP_STAMP" ]; then
  backup_age=$(( now - $(stat -c %Y "$BACKUP_STAMP" 2>/dev/null || echo "$now") ))
fi

# "ts" = write time of this run (staleness guard, see benno-zabbix.conf).
write_json "$STATUS" "$(printf '{"ts":%s,"collector_ok":%s,"journal_ok":%s,"last_ok_epoch":%s,"last_ok_age":%s,"inbox_queue":%s,"pop3_err_20m":%s,"import_err_20m":%s,"import_err_last_epoch":%s,"web_cert_days":%s,"ntp_synced":%s,"postfix_queue":%s,"systemd_failed":%s,"license_days":%s,"imapimport_last":%s,"imapimport_age":%s,"inbox_err_aged":%s,"inbox_prc_aged":%s,"backup_age":%s}' \
  "$now" "$collector_ok" "$journal_ok" "${last:-0}" "$age" "$inbox" "${recent_err:-0}" "$import_err_20m" "$import_err_last_epoch" "$web_cert_days" "$ntp_synced" "$postfix_queue" "$systemd_failed" "$license_days" "$imapimport_last" "$imapimport_age" "$inbox_err_aged" "$inbox_prc_aged" "$backup_age")" \
  || echo "benno-zabbix: failed to write $STATUS" >&2

# --- Archive size (expensive: only every ARCHIVE_CACHE_MAX_AGE seconds) ---
# On a measurement error (missing dir / du or find fails / timeout) we do NOT
# overwrite with zeros: the previous file (and its old ts) is kept, so the
# template's archive-ts staleness trigger surfaces the stall instead.
cage=99999999; [ -f "$AT" ] && cage=$(( now - $(stat -c %Y "$AT" 2>/dev/null || echo 0) ))
if [ "$cage" -gt "$ARCHIVE_CACHE_MAX_AGE" ]; then
  if [ -d "$ARCHIVE_DIR" ] && [ -d "$ARCHIVE_REPO_DIR" ]; then
    bytes=$(timeout "$DU_TIMEOUT" du -sb "$ARCHIVE_DIR" 2>/dev/null | awk 'NR==1{printf "%d\n", $1}'); du_rc=${PIPESTATUS[0]}
    files=$(timeout "$DU_TIMEOUT" find "$ARCHIVE_REPO_DIR" -type f 2>/dev/null | wc -l); find_rc=${PIPESTATUS[0]}
    if [ "$du_rc" -eq 0 ] && [ "$find_rc" -eq 0 ] && [ -n "${bytes:-}" ]; then
      write_json "$AT" "$(printf '{"ts":%s,"archive_total_bytes":%s,"archive_total_files":%s}' "$now" "${bytes:-0}" "${files:-0}")" \
        || echo "benno-zabbix: failed to write $AT" >&2
    else
      echo "benno-zabbix: archive scan failed (du=$du_rc find=$find_rc); keeping previous totals" >&2
    fi
  else
    echo "benno-zabbix: archive dir missing ($ARCHIVE_DIR / $ARCHIVE_REPO_DIR); keeping previous totals" >&2
  fi
fi
