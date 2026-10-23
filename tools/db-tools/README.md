# db-tools

Read-only query wrappers that let a coding agent look at real data in PostgreSQL, MongoDB, Elasticsearch and
Redis. Every call names its target, results are capped, timed out and masked, and every call leaves an audit
line, refused or not. Where a store can refuse writes itself, it is made to.

```
$ pg-query.sh --profile staging -q "SELECT id, email FROM users ORDER BY id DESC" --limit 2
 id  |       email
-----+-------------------
 912 | ma**@example.com
 911 | jo**@example.org
(2 rows)
db-tools: 2 rows is the --limit; the result may continue (raise --limit, or page with --offset)

$ mongo-query.sh --profile staging -q 'db.orders.find({status: "open"}, {total: 1})' --limit 2
{"_id":{"$oid":"6650a1c2e4b0f3a1c2d3e4f5"},"total":120.5}
{"_id":{"$oid":"6650a1c2e4b0f3a1c2d3e4f6"},"total":42}
db-tools: 2 result(s); reached --limit 2, there may be more
```

Works with: Claude Code. Any harness with a shell can call them the same way; untested there.

## Why

An agent that can read the data answers questions about it instead of reconstructing them from code. Handing
it `psql` or `mongosh` means trusting every command it writes, including the one it writes when confused. These
wrappers make the usual reads one command each and the usual accidents loud: there is no default connection, a
row cap does not depend on rewriting the query, a statement cannot run longer than ten minutes, personal data
is masked, and nothing reaches a store without a line in the log.

They are a second layer ([D9](../../docs/decisions.md)). The boundary is the account each profile uses: see
[What they do not protect against](#what-they-do-not-protect-against).

## What's inside

| Script | Store | What it does |
|---|---|---|
| `scripts/pg-query.sh` | PostgreSQL | One `SELECT`, `WITH`, `VALUES`, `TABLE`, `EXPLAIN` or `SHOW`, in a read-only transaction that is always rolled back |
| `scripts/mongo-query.sh` | MongoDB | One mongosh expression, behind a text check and a runtime guard; prints one EJSON line per document |
| `scripts/mongo-explain.sh` | MongoDB | Has the server plan an update or delete without running it, to check a spec such as `arrayFilters` |
| `scripts/es-query.sh` | Elasticsearch | One request to a read API: `_search`, `_count`, `_msearch`, `_mapping`, `_field_caps`, `_cat` |
| `scripts/redis-query.sh` | Redis | Inspect a key, run one read command, or scan keys at a bounded pace; decodes MessagePack values |
| `scripts/refresh-schema.sh` | PostgreSQL, MongoDB | Writes the schema to local files, so the agent reads structure without running a query |

## Install

```sh
mkdir -p ~/.agents/tools
cp -R tools/db-tools ~/.agents/tools/
(cd ~/.agents/tools/db-tools && npm ci --omit=dev)    # only for redis-query.sh
mkdir -p ~/.config/db-tools
cp ~/.agents/tools/db-tools/env.example ~/.config/db-tools/.env
chmod 600 ~/.config/db-tools/.env
```

Every script needs `bash`, `jq` and `python3`. Then, per store: `psql` and `pg_dump` for PostgreSQL, `mongosh`
for MongoDB, `curl` for Elasticsearch, and Node.js 18 or later for Redis.

So that Claude Code can run them without a prompt, allow the wrappers and keep the raw clients behind one. A
rule matches the command text, so the agent must call each script by exactly this spelling:

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.agents/tools/db-tools/scripts/pg-query.sh:*)",
      "Bash(~/.agents/tools/db-tools/scripts/mongo-query.sh:*)",
      "Bash(~/.agents/tools/db-tools/scripts/es-query.sh:*)",
      "Bash(~/.agents/tools/db-tools/scripts/redis-query.sh:*)"
    ],
    "ask": ["Bash(psql:*)", "Bash(mongosh:*)", "Bash(redis-cli:*)"]
  }
}
```

`mongo-explain.sh` and `refresh-schema.sh` are rarer; leave them to a prompt or allow them the same way.

## Configure

A profile is a prefix. `--profile STAGING` reads the `STAGING_*` settings:

| Setting | Used by |
|---|---|
| `NAME_PG_URI` | `pg-query.sh`, `refresh-schema.sh` |
| `NAME_MONGO_URI` | `mongo-query.sh`, `mongo-explain.sh`, `refresh-schema.sh` |
| `NAME_ES_URL` or `NAME_ES_CLOUD_ID`, and `NAME_ES_API_KEY` or `NAME_ES_CREDENTIAL` (with `NAME_ES_AUTH`) | `es-query.sh` |
| `NAME_REDIS_URI` | `redis-query.sh` |

Settings come from `~/.config/db-tools/.env` or from the environment, which wins. Values in the file are taken
literally, so `&` and `$` in a password need no escaping; in a PostgreSQL URI, percent-encode `?`, `/`, `#` and
`%`. [`env.example`](env.example) shows every setting.

There is no default profile ([D10](../../docs/decisions.md)), so no call reaches a system nobody named. Nothing
from the file is exported: each client gets only the one connection string it uses, in its environment, never
on its command line, where `ps` would show it.

| Variable | Default | What |
|---|---|---|
| `DBTOOLS_ENV_FILE` | `~/.config/db-tools/.env` | The settings file |
| `DBTOOLS_LOG_FILE` | `~/.local/state/db-tools/queries.jsonl` | The audit log |
| `DBTOOLS_SCHEMA_DIR` | `~/.local/share/db-tools/schema` | Where `refresh-schema.sh` writes, one directory per profile |
| `DBTOOLS_NODE_PATH` | the tool's `node_modules` | Where `redis-query.sh` finds `ioredis` and `@msgpack/msgpack` |

## Use

### Schema first

```sh
refresh-schema.sh --profile STAGING
```

It writes `postgres.sql` (`pg_dump --schema-only`) and `mongo.md` (each collection's estimated count, indexes
and one sample document, masked) to `~/.local/share/db-tools/schema/STAGING/`. Most structural questions are
answered there, at no cost to the database.

### PostgreSQL

```sh
pg-query.sh --profile STAGING -q "SELECT status, count(*) FROM orders GROUP BY 1" [--limit N] [--offset N]
```

What psql receives, as separate commands in one session that stops at the first error:

```sql
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '600s';
SET LOCAL standard_conforming_strings = on;
DECLARE db_tools_cursor NO SCROLL CURSOR FOR <the statement>;
MOVE FORWARD <offset> IN db_tools_cursor;        -- with --offset
FETCH FORWARD <limit> FROM db_tools_cursor;      -- --limit, 1..10000, default 100
ROLLBACK;
```

`EXPLAIN` and `SHOW` run directly in place of the cursor lines. Before any of this, `lib/pgcheck.py` lexes the
text the way PostgreSQL does (quotes, `E''` escapes, dollar quotes, quoted identifiers, nested comments) and
refuses it unless it is exactly one statement that starts with a read keyword and names none of the functions
whose effects a rollback cannot undo, such as `pg_terminate_backend`, `pg_reload_conf`, `pg_read_file`,
`dblink` or `query_to_xml`. A `;` or a function name inside a string or a comment is just text, and there is
no keyword denylist: a column called `vacuum` is fine, and a write is refused by the server.

For a large table, page by key (`WHERE id > <last id> ORDER BY id`) rather than by `--offset`.

### MongoDB

```sh
mongo-query.sh --profile STAGING -q 'db.orders.aggregate([{$group: {_id: "$status", n: {$sum: 1}}}])'
```

The expression is one JavaScript expression: a `find`, an `aggregate`, a `countDocuments`, a
`getCollectionNames()`. Its value prints as one relaxed EJSON line per document, so an ObjectId shows as
`{"$oid": …}` and a date as `{"$date": …}`, at most `--limit` lines (1..10000, default 100), with a summary on
stderr. `find()` gets `--limit` and `--skip` as its own limit and skip; `find`, `aggregate` and
`countDocuments` get a ten-minute `maxTimeMS` unless the query sets one. Reads go to a secondary when there is
one.

Two layers stand between the expression and a write:

1. A text check in `lib/safety.sh` looks at the expression twice. In the raw text, strings included, it refuses
   names a read never needs: `$out`, `$merge`, server-side JavaScript (`$where`, `$function`, `$accumulator`,
   `mapReduce`), modules and the process (`require`, `load`, `process`), `constructor` and `prototype`, and the
   driver's own client and command runners. In the code alone, with strings, regular expressions and comments
   blanked by [`lib/jsblank.py`](lib/jsblank.py), it refuses a second statement, `eval` and `Function`, `this`,
   `global`, `Object` and `Reflect`, a write method called in any form (after whitespace or a comment, with
   optional chaining, as a tagged template, through `call`, `apply` or `bind`), any computed member or key other
   than a numeric index, destructuring assignment, any name that starts with an underscore other than `_id` (the
   shell's internals, the driver handle among them), and the replica set, sharding and stream helpers. A `;`,
   a `[` or a leading `_` inside a string or a regular expression is data.
2. mongosh then runs [`lib/mongo-guard.js`](lib/mongo-guard.js) before the expression. It replaces every write
   method of the shell's `Collection`, `Database` and `Mongo` prototypes with one that throws, pins it so it
   cannot be put back, and refuses pipelines with `$out` or `$merge`; an alias, `call`, a sibling database, a
   session or a second connection all end on those prototypes. It does the same one level down, on the
   service provider and the driver's `Collection`, `Db` and `MongoClient`. Their generic command runners stay,
   because the shell's own reads use them, so those are closed only by the text check.

`mongo-explain.sh --profile STAGING --collection orders < spec.json` sends one update or delete spec, as
extended JSON, inside `explain` with the `queryPlanner` verbosity, which plans the write and never applies it.
It prints `ACCEPTED` or `REJECTED` with the server's reason.

### Elasticsearch

```sh
es-query.sh --profile STAGING -i products --endpoint _count -q '{"query": {"term": {"brand": "acme"}}}'
es-query.sh --profile STAGING --endpoint _cat/indices
```

A request with a body is a `POST`, without one a `GET`. Only read APIs are reachable, every path segment must
be a plain name, and curl sends the path exactly as it was checked: by default curl collapses `.` and `..`
segments, which would turn `_search/../_doc/1` into a write. The URL and the credentials reach curl through a
config on a pipe.

### Redis

```sh
redis-query.sh --profile STAGING -q 'session:42'                       # EXISTS, TTL, type, the decoded value
redis-query.sh --profile STAGING -q 'scores' --cmd ZRANGE --arg 0 --arg 9
redis-query.sh --profile STAGING --scan 'session:*' --max-keys 50
```

`--cmd` takes one command from a read allowlist, checked in the wrapper and again in
[`lib/redis-exec.js`](lib/redis-exec.js); `MEMORY` is limited to `MEMORY USAGE`. Keys are listed only with
`--scan`, which pages `SCAN` within a key and round-trip budget and says whether it covered the whole keyspace;
`KEYS` is never sent. String values that parse as MessagePack are decoded to JSON.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Refused by db-tools, before or (for MongoDB) during the run |
| 2 | Usage or configuration error; nothing ran |
| 3 | The store returned an error or could not be reached |

A refused or failed call prints nothing on stdout. Piped into `grep`, it reads as "nothing found": check the
exit code before trusting an empty result.

## Audit log

One JSON line per call in `~/.local/state/db-tools/queries.jsonl` (mode 600): time, store, profile, outcome
(`ok`, `refused`, `failed`), the reason, the masked query, limits, row or result count, duration, and whether
the output was unmasked. A refusal also records the arguments as given. Results are never logged. When the log
cannot be written, nothing runs.

```sh
jq -c 'select(.outcome == "refused") | {ts, db, reason, query}' ~/.local/state/db-tools/queries.jsonl
jq -s 'sort_by(-.duration_ms) | .[:5] | map({db, duration_ms, query})' ~/.local/state/db-tools/queries.jsonl
```

## Masking

Output and the log go through [`lib/mask.py`](lib/mask.py): an e-mail keeps two characters of its local part and
its domain, an E.164 phone number keeps its first and last two digits, and a hex token of 32 or more characters
keeps four at each end. A password in a URL is always redacted. `--unmask` shows personal data only when the user
has also set `DB_TOOLS_ALLOW_UNMASK=1` in their own shell, and the log records it.

Masking rewrites values that are not personal: an `md5()` digest comes back as `2a34****c45d`. Compare such
values inside the query, not after it.

## What they do not protect against

- **An account that may write.** Give every profile an account that can only read: a PostgreSQL role with
  `SELECT` on what it needs and without `pg_signal_backend` or file-reading roles; a MongoDB user with only the
  `read` role; an Elasticsearch API key with read privileges on the indices it needs; a Redis ACL user limited to
  read commands. With such an account, everything below is a mistake the store refuses anyway.
- **PostgreSQL:** a function with a side effect outside SQL that is not on the denylist, from an extension or
  written in C; SQL-level writes inside any function are refused by the read-only transaction.
- **MongoDB:** both layers check JavaScript, which no pattern covers completely. The guard pins write methods,
  not the driver's generic command runner, which the shell's reads need; an expression that reached that runner
  past the text check could send any command. `secondaryPreferred` keeps reads off the primary; it does not make
  a connection read-only.
- **Cost.** A read can still be heavy: a sequential scan of a large table, an unindexed MongoDB filter, an
  expensive aggregation. The timeouts bound it to ten minutes; `EXPLAIN` first when unsure.
- **Personal data that is not an e-mail, a phone number or a token.** Names, addresses and free text stay
  visible.
- **The log as a control.** It is a local file the agent can read and change: a record, not a gate.

## Measured

The design comes from running the private version of these wrappers against production stores for months. Each
of these was seen there before it was fixed:

- A row cap made by appending `LIMIT` switches itself off whenever the query has a `LIMIT` anywhere, a subquery
  included, and an offset appended after the check is unchecked SQL: `--offset "0; DELETE …"` became a second
  statement. Here the cap is a cursor and every count is a validated integer.
- A keyword denylist over SQL refused `WHERE relname = 'vacuum'` and a comment on the first line, and let
  `SELECT … INTO` create a table. Here the server refuses the write.
- curl turned `--endpoint '_search/../_doc/1'` into a `POST` to `_doc/1`.
- mongosh `--eval` can `require('child_process')`, so an allow-listed MongoDB wrapper was also a shell, and a
  secret exported to its environment was one `print(process.env)` away.
- mongosh prints the first 20 documents of a cursor and stops. A 5,000-id export through it returned at most 20
  ids per call without an error.
- `JSON.stringify` turns an ObjectId into a string. A query that then matched `{_id: "<hex>"}` found nothing,
  and the zero looked like an answer. The EJSON output keeps the type.

## Test

```sh
bats tools/db-tools/tests/
python3 -m unittest discover -s tools/db-tools/tests -t tools/db-tools/tests
node --test tools/db-tools/tests/*.test.mjs
```

The wrapper tests put fake clients first on `PATH` that record their arguments, environment and stdin, so a
test can show that a password never reached a command line and that a refused query never reached a client.
`tests/test_pg_server.bats` starts a throwaway PostgreSQL with `initdb` and shows that the server refuses the
writes the lexer lets through and rolls back what read-only mode allows. The Redis decoder tests need
`npm ci` in the tool directory. Without `initdb` or the Node dependencies those tests skip, unless
`DBTOOLS_REQUIRE_INTEGRATION=1`, which CI sets, makes that a failure.
