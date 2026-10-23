#!/usr/bin/env bash
# pg_uri.sh — turn a postgres URI into libpq environment variables, so that neither psql nor pg_dump gets
# the password on its command line, where any process could read it with ps.

# parse_pg_uri URI — export PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE and, when the URI has them,
# PGSSLMODE and PGSSLROOTCERT. An empty part is left unset, so libpq falls back to its defaults (a missing
# password to ~/.pgpass). A password in the URI must be percent-encoded where it contains ? / # or %.
# Variables that could redirect the connection or change the session (PGSERVICE, PGOPTIONS) are cleared.
# Exports reach every later child of the shell, so call it in the subshell that runs the client.
parse_pg_uri() {
    local exports
    # The URI goes in on stdin: as an argument it would show up in ps for the life of the parser.
    exports=$(printf '%s' "$1" | python3 -I -c '
import shlex, sys, urllib.parse as u
p = u.urlparse(sys.stdin.read().strip())
if p.scheme not in ("postgres", "postgresql") or not p.hostname:
    sys.exit(1)
out = {
    "PGHOST": p.hostname,
    "PGPORT": str(p.port or 5432),
    "PGUSER": u.unquote(p.username or ""),
    "PGPASSWORD": u.unquote(p.password or ""),
    "PGDATABASE": u.unquote(p.path.lstrip("/")),
}
query = dict(u.parse_qsl(p.query))
for key, var in (("sslmode", "PGSSLMODE"), ("sslrootcert", "PGSSLROOTCERT")):
    if key in query:
        out[var] = query[key]
for var, value in out.items():
    if value:
        print("export " + var + "=" + shlex.quote(value))
') || return 1
    unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE PGSSLROOTCERT PGSERVICE PGSERVICEFILE PGOPTIONS
    eval "$exports"
    export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
}
