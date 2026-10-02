#!/usr/bin/env bash
# Initialize the SchedPilot MySQL benchmark instance (port 3307), install the
# reference config, grant local TCP access and prepare sysbench data.
#
#   scripts/setup_mysql.sh
#
# Must run as root on the benchmark VM. Idempotent: re-running keeps existing
# data and just restarts/verifies the instance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MYSQL_CNF="${MYSQL_CNF:-/etc/schedpilot-mysql.cnf}"
DATADIR=/var/lib/schedpilot-mysql
RUNDIR=/var/run/schedpilot-mysql
LOGDIR=/var/log/schedpilot-mysql
TABLES="${TABLES:-4}"
TABLE_SIZE="${TABLE_SIZE:-200000}"

[ "$(id -u)" = "0" ] || { echo "[FAIL] must run as root" >&2; exit 1; }

for bin in mysqld mysqladmin mysql; do
	command -v "$bin" >/dev/null 2>&1 || {
		echo "[info] installing mysql-server ..."
		(dnf -y install mysql-server || yum -y install mysql-server) >/dev/null
		break
	}
done
command -v sysbench >/dev/null 2>&1 || {
	echo "[info] installing sysbench ..."
	(dnf -y install sysbench || yum -y install sysbench) >/dev/null
}

echo "[setup] installing $MYSQL_CNF"
install -m 600 "$ROOT/bench/mysql-schedpilot.cnf" "$MYSQL_CNF"
mkdir -p "$DATADIR" "$RUNDIR" "$LOGDIR"
chown -R mysql:mysql "$DATADIR" "$RUNDIR" "$LOGDIR"

if [ ! -d "$DATADIR/mysql" ]; then
	echo "[setup] initializing datadir ..."
	mysqld --defaults-file="$MYSQL_CNF" --initialize-insecure
fi

if ! mysqladmin --defaults-file="$MYSQL_CNF" ping >/dev/null 2>&1; then
	echo "[setup] starting mysqld ..."
	mysqld --defaults-file="$MYSQL_CNF" --daemonize
	for _ in $(seq 1 30); do
		mysqladmin --defaults-file="$MYSQL_CNF" ping >/dev/null 2>&1 && break
		sleep 0.5
	done
fi

mysql --defaults-file="$MYSQL_CNF" -uroot <<'EOF'
CREATE DATABASE IF NOT EXISTS schedpilot;
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

if ! mysql --defaults-file="$MYSQL_CNF" -uroot -e 'SELECT 1 FROM schedpilot.sbtest1 LIMIT 1' >/dev/null 2>&1; then
	echo "[setup] preparing sysbench data (tables=$TABLES size=$TABLE_SIZE) ..."
	sysbench oltp_read_only --mysql-host=127.0.0.1 --mysql-port=3307 \
		--mysql-user=root --mysql-db=schedpilot \
		--tables="$TABLES" --table-size="$TABLE_SIZE" prepare
fi

echo "[setup] verifying ..."
mysqladmin --defaults-file="$MYSQL_CNF" ping
sysbench oltp_read_only --mysql-host=127.0.0.1 --mysql-port=3307 \
	--mysql-user=root --mysql-db=schedpilot --tables="$TABLES" \
	--threads=4 --time=3 --percentile=99 run | tail -n 12
echo "[setup] done"
