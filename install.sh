#!/usr/bin/env bash
#
# Installer for the Benno MailArchiv agent-side monitoring.
#
# Installs the root-cron collector, its UserParameter config and the cron entry,
# detects the Zabbix agent flavour (agent2 or classic agentd) and its include
# directory, removes any older copy that would register the same UserParameters
# twice (a duplicate makes the agent refuse to start), primes the collector once,
# restarts the agent and self-tests both keys.
#
# Run as root on the Benno host, from a checkout of this repo:
#   sudo ./install.sh
#
# Idempotent: re-running it just refreshes the files and re-tests.
#
# Author / vendor: Alexander Fox | PlaNet Fox -- https://planetfox.biz

set -euo pipefail

STATE_DIR="/var/lib/benno-zabbix"
SCRIPT_DST="/usr/local/bin/benno-zabbix-status.sh"
CRON_DST="/etc/cron.d/benno-zabbix"
CONF_NAME="benno-zabbix.conf"

say()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo ./install.sh)."

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$SRC_DIR/agent"
for f in benno-zabbix-status.sh "$CONF_NAME" benno-zabbix.cron; do
	[ -r "$AGENT_DIR/$f" ] || die "Missing $AGENT_DIR/$f -- run from a full checkout."
done

# --- Detect the agent flavour ----------------------------------------------
if [ -x /usr/sbin/zabbix_agent2 ] || command -v zabbix_agent2 >/dev/null 2>&1; then
	BIN="$(command -v zabbix_agent2 || echo /usr/sbin/zabbix_agent2)"
	SVC="zabbix-agent2"
	CONF="/etc/zabbix/zabbix_agent2.conf"
	DEFDIR="/etc/zabbix/zabbix_agent2.d"
elif [ -x /usr/sbin/zabbix_agentd ] || command -v zabbix_agentd >/dev/null 2>&1; then
	BIN="$(command -v zabbix_agentd || echo /usr/sbin/zabbix_agentd)"
	SVC="zabbix-agent"
	CONF="/etc/zabbix/zabbix_agentd.conf"
	DEFDIR="/etc/zabbix/zabbix_agentd.conf.d"
else
	die "No Zabbix agent found (zabbix_agent2 or zabbix_agentd). Install the agent first."
fi
say "Agent: $BIN (service $SVC)"

# --- Resolve the include directory from the running config ------------------
INCDIR=""
if [ -r "$CONF" ]; then
	INCDIR="$(grep -E '^Include=.*/\*\.conf[[:space:]]*$' "$CONF" 2>/dev/null \
		| sed 's/^Include=//; s/[[:space:]]*$//' \
		| grep -v '/plugins\.d/' | head -1 || true)"
	INCDIR="${INCDIR%/\*.conf}"
fi
[ -n "$INCDIR" ] || INCDIR="$DEFDIR"
[ -d "$INCDIR" ] || die "Include directory $INCDIR does not exist -- is the agent configured?"
CONF_DST="$INCDIR/$CONF_NAME"
say "Include dir: $INCDIR"

# --- Remove older copies that register the same UserParameters --------------
# A second file defining benno.status / benno.archive_total makes the agent
# fail to start on a duplicate key. Drop any such file that is not our target.
shopt -s nullglob
for f in "$INCDIR"/*.conf; do
	[ "$f" = "$CONF_DST" ] && continue
	if grep -qE '^UserParameter=benno\.(status|archive_total)' "$f" 2>/dev/null; then
		say "Removing conflicting legacy config: $f"
		rm -f "$f"
	fi
done
shopt -u nullglob

# --- Install ----------------------------------------------------------------
# Root-owned state dir: only root writes, the agent reads (symlink safety).
say "Installing files"
install -d -m755 -o root -g root "$STATE_DIR"
install -m755 "$AGENT_DIR/benno-zabbix-status.sh" "$SCRIPT_DST"
install -m644 "$AGENT_DIR/$CONF_NAME"             "$CONF_DST"
install -m644 "$AGENT_DIR/benno-zabbix.cron"      "$CRON_DST"

# --- Prime the collector once (first run scans the archive, can take ~2 min) -
say "Priming collector (first run scans the archive, this can take a minute)..."
if ! "$SCRIPT_DST"; then
	say "WARNING: collector returned non-zero on first run -- check paths in its CONFIG block."
fi

# --- Restart the agent and self-test ----------------------------------------
say "Restarting $SVC"
systemctl restart "$SVC"

say "Self-test:"
rc=0
"$BIN" -t benno.status        || rc=1
"$BIN" -t benno.archive_total || rc=1
if [ "$rc" -ne 0 ]; then
	die "Agent test failed. Check: systemctl status $SVC  and  journalctl -u $SVC -n 50"
fi

cat <<EOF

Done. The agent side is installed.

Next, on the Zabbix frontend:
  1. Import template_app_benno_mailarchiv_agent.yaml (Data collection -> Templates -> Import).
  2. Link it to this host and set the host macros (see README / grafana docs).
     In particular {\$BENNO_POP3_HOST} must point at your real POP3 source.

Config name on this host: $CONF_DST
EOF
