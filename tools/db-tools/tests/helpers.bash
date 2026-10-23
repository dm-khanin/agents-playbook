# helpers.bash — shared setup for the db-tools bats suites. Load it with `load helpers`.
#
# Every assertion that is not a test's last command ends in `|| false`: bash 3.2, the macOS default, does not
# fail a test on a false [[ ]] in the middle, and no bash fails one on a bare `! cmd`.

TOOL_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SCRIPTS="$TOOL_DIR/scripts"

common_setup() {
    DBTESTDIR="$(mktemp -d)"
    export DBTESTDIR
    export DBTOOLS_ENV_FILE="$DBTESTDIR/config.env"
    export DBTOOLS_LOG_FILE="$DBTESTDIR/state/queries.jsonl"
    export DBTOOLS_SCHEMA_DIR="$DBTESTDIR/schema"
    export PATH="$DBTESTDIR/bin:$PATH"
    unset DB_TOOLS_ALLOW_UNMASK DBTOOLS_NODE_PATH
    mkdir -p "$DBTESTDIR/bin"
    : > "$DBTOOLS_ENV_FILE"
}

common_teardown() {
    rm -rf "$DBTESTDIR"
}

# config LINE... — append lines to the config file.
config() {
    printf '%s\n' "$@" >> "$DBTOOLS_ENV_FILE"
}

# fake_client NAME — put a stand-in for NAME first on PATH. Each run records its arguments, its environment,
# the text of a -K file (curl's config) and, when an argument is @-, its stdin: the last run in
# $DBTESTDIR/NAME.json, every run as a line of NAME.calls.jsonl. Then it prints $DBTESTDIR/NAME.stdout and
# NAME.stderr and exits with the number in NAME.status, each when present.
fake_client() {
    cat > "$DBTESTDIR/bin/$1" <<EOF
#!/usr/bin/env python3
import json, os, sys
state, name = "$DBTESTDIR", "$1"
args = sys.argv[1:]
record = {"argv": args, "env": dict(os.environ)}
if "-K" in args:
    with open(args[args.index("-K") + 1]) as config:
        record["config"] = config.read()
if "@-" in args:
    record["stdin"] = sys.stdin.read()
with open(os.path.join(state, name + ".json"), "w") as out:
    json.dump(record, out)
with open(os.path.join(state, name + ".calls.jsonl"), "a") as out:
    out.write(json.dumps(record) + "\n")
def replay(suffix, stream):
    path = os.path.join(state, name + suffix)
    if os.path.exists(path):
        with open(path) as f:
            stream.write(f.read())
replay(".stdout", sys.stdout)
replay(".stderr", sys.stderr)
path = os.path.join(state, name + ".status")
sys.exit(int(open(path).read()) if os.path.exists(path) else 0)
EOF
    chmod +x "$DBTESTDIR/bin/$1"
}

# answer NAME STDOUT [STDERR [STATUS]] — what the fake NAME prints and returns.
answer() {
    printf '%s' "$2" > "$DBTESTDIR/$1.stdout"
    if [ $# -ge 3 ]; then printf '%s' "$3" > "$DBTESTDIR/$1.stderr"; fi
    if [ $# -ge 4 ]; then printf '%s' "$4" > "$DBTESTDIR/$1.status"; fi
}

# recorded NAME FILTER — jq -e FILTER over what the fake NAME recorded.
recorded() {
    jq -e "$2" "$DBTESTDIR/$1.json" > /dev/null
}

# calls NAME FILTER — jq -e FILTER over the array of every run of the fake NAME, in order.
calls() {
    jq -se "$2" "$DBTESTDIR/$1.calls.jsonl" > /dev/null
}

# not_called NAME — the fake NAME never ran.
not_called() {
    [ ! -e "$DBTESTDIR/$1.json" ]
}

# mode_of PATH — the permission bits as octal digits. Not stat: its flags differ between BSD and GNU, and
# GNU stat -f succeeds with something else entirely.
mode_of() {
    python3 -I -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"
}

# last_audit FILTER — jq -e FILTER over the last audit line.
last_audit() {
    tail -n 1 "$DBTOOLS_LOG_FILE" | jq -e "$1" > /dev/null
}
