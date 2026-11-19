#!/bin/sh
# Integration tests against the public VictoriaMetrics and VictoriaLogs
# playgrounds (play.victoriametrics.com, play-vmlogs.victoriametrics.com):
# builds and installs the extension into the PostgreSQL of PG_CONFIG, starts
# a throwaway cluster in _pgtest/<version>/ and runs test/*.sql, each in its
# own session (checks raise errors).
#
#   sh test/run.sh [pg_config]        GOPGEXT=path/to/gopgext to override
set -eu

PG_CONFIG=${1:-${PG_CONFIG:-pg_config}}
GOPGEXT=${GOPGEXT:-$(command -v gopgext || echo ../gopgext/gopgext)}
BIN=$("$PG_CONFIG" --bindir)
VER=$("$PG_CONFIG" --version | awk '{print $2}')
DIR=$(pwd)/_pgtest/$VER
PORT=${PGTEST_PORT:-5479}

"$GOPGEXT" install -pg-config "$PG_CONFIG" -comment 'Foreign data wrapper for VictoriaMetrics and VictoriaLogs' . >/dev/null
rm -rf "$DIR"
mkdir -p "$DIR"
"$BIN/initdb" -D "$DIR/data" -A trust -U postgres -E UTF8 --locale=C >"$DIR/initdb.log" 2>&1
"$BIN/pg_ctl" -D "$DIR/data" -l "$DIR/server.log" -w \
	-o "-k $DIR -c listen_addresses= -p $PORT" start >/dev/null
trap '"$BIN/pg_ctl" -D "$DIR/data" -m fast -w stop >/dev/null' EXIT

fail=0
for t in test/*.sql; do
	name=$(basename "$t" .sql)
	if "$BIN/psql" -X -q -h "$DIR" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -f "$t" postgres >"$DIR/$name.log" 2>&1; then
		echo "PASS: $name (PostgreSQL $VER)"
	else
		echo "FAIL: $name (PostgreSQL $VER)"
		cat "$DIR/$name.log"
		fail=1
	fi
done
if grep -E "TRAP:|PANIC:|terminated by signal" "$DIR/server.log"; then
	echo "FAIL: server crashed (see $DIR/server.log)"
	fail=1
fi
exit $fail
