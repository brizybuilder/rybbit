# One-off ClickHouse migrations

The schema in `server/src/db/clickhouse/schema/` is applied with
`CREATE TABLE IF NOT EXISTS`, so changing a column there only affects **new**
installations. An existing deployment needs the matching script from this
directory, run once, before the new image starts serving traffic.

## 2026-09-21 — site_id UInt16 -> UInt32

`sites.site_id` in Postgres is a `serial`: it counts up to 2.1 billion and never
reuses a number, not even after a site is deleted. The ClickHouse tables
declared the same column as `UInt16`, which tops out at 65535.

Past that point the failure is quiet, and it lands on the wrong customer rather
than on the one who overflowed. ClickHouse does not reject an out-of-range id:
it stores the value modulo the column width. Site `70000` is written as
`70000 - 65536 = 4464`, so its pageviews are filed under whichever site really
holds id 4464 and appear in that customer's reports. `POST /api/track` answers
`{"success":true}`, nothing is logged, and the site that overflowed simply shows
no data.

Verified against ClickHouse 26.3.17.4: a batch containing `site_id` 70000
inserted without error and came back out as 4464.

`site_id` is the first column of `ORDER BY (site_id, timestamp)`, and ClickHouse
rejects `ALTER TABLE ... MODIFY COLUMN` on a key column. Each table is recreated
from its own live DDL and swapped in with `EXCHANGE TABLES`, which is atomic on
an `Atomic` database. Widening an unsigned integer preserves sort order, so the
rows copy across as they are.

### Running it

Ingestion must be stopped: rows written to the old table between the copy and
the swap are lost.

```bash
ops/migrations/pre-migration-snapshot.sh create   # and verify it before going on
docker compose stop backend
DRY_RUN=1 ops/migrations/2026-09-21-site-id-uint32.sh   # lists the tables, changes nothing
ops/migrations/2026-09-21-site-id-uint32.sh
docker compose start backend
```

Each table's pre-migration rows are kept as `<table>__pre_uint32`, so the swap
can be undone in one statement while the new schema is being watched:

```sql
EXCHANGE TABLES events AND events__pre_uint32
```

Drop those copies once the instance has run on `UInt32` long enough to trust
it. `DROP_OLD=1` discards them during the run instead, which leaves no way
back and is not what you want on a first run.

### Memory

The rows are copied a day at a time, not in one `INSERT ... SELECT`. On a small
host ClickHouse caps its own memory well below the machine's RAM — on a 4 GB
box the ceiling lands near 1 GiB and the server already holds most of it — so
copying a table of a million rows, or even a single month of one, dies with
`MEMORY_LIMIT_EXCEEDED` partway through. Nothing is lost when that happens: the
swap has not run and the original is untouched. The half-filled copy stays on
disk, and the next run refuses to start until you look at it and drop it - it
reports how many rows it holds so you can tell a stalled copy from a finished
one. The migration stops, and on a production instance it stops with ingestion
already halted.

Not every table calls its time column `timestamp` — the hourly aggregates use
`event_hour`, the session tables `start_time` or `session_hour` — so the script
slices by whichever one exists and says which it used. Only a table with no time
column at all is copied in one statement, and it says that too. Each insert runs
with `max_threads = 1`, `max_insert_threads = 1` and `max_block_size = 8192`,
which keeps the peak flat instead of proportional to the slice.

### What it checks before swapping

The row counts have to match, but a plain `count()` is the wrong question for
some engines. A Replacing, Summing, Aggregating or Collapsing table merges the
freshly written copy in the background and folds rows with equal sort keys, so
the copy legitimately reports fewer rows than the source — the old check refused
to swap and left the instance half migrated with ingestion stopped. Those
engines are now counted with `FINAL` on both sides. A table with a TTL has the
same problem from the other direction: the new table expires rows sooner than
the source did, so TTL merges are stopped on the copy until the comparison is
done.

It also re-reads the source afterwards. If a day appeared that was not in the
list, or the table simply grew, something was still writing and the copy is
incomplete — the script says so and stops instead of swapping a table that is
missing rows.

The script picks its own targets (`system.columns` where `site_id` is still
`UInt16`, MergeTree family only), and refuses to run over a leftover `*__u32`
copy or an existing `*__pre_uint32` from an earlier run. If an earlier run died
between the swap and the rename it recognises that state — the live table is
already `UInt32` while the copy still holds the pre-migration rows — and prints
the one command that finishes it, rather than reporting nothing to do. It is a
no-op on an installation that is already migrated.

Deploy the matching image afterwards: its queries bind site ids as `UInt32`, and
older images bind them as `UInt16`, which truncates any id above 65535.

## 2026-09-21 — orphaned event data

Deleting a site used to clear only `session_replay_events` and
`session_replay_metadata_v2`. Its pageviews, bot events and observations stayed
in ClickHouse for good.

Nothing in the product shows those rows — every report is scoped to a site that
exists — so they were merely dead weight. The risk is what happens if an id is
ever handed out twice: reuse a number by hand, or reset `sites_site_id_seq`, and
the new site inherits a stranger's history and shows it as its own. The fix in
this branch clears every table that carries `site_id` on delete; this script
cleans up what earlier deletions left behind.

```bash
ops/migrations/2026-09-21-purge-orphaned-site-data.sh          # report only
APPLY=1 ops/migrations/2026-09-21-purge-orphaned-site-data.sh  # delete
```

Postgres is the source of truth: any `site_id` in ClickHouse with no `sites` row
is removed. The script refuses to do anything if Postgres reports zero sites,
since that is far more likely to be a broken connection than a genuinely empty
instance.

## 2026-09-21 — unique public site id

`sites.id` — the six random bytes a tracking snippet and the report routes carry
— had no unique index, only a primary key on the numeric `site_id`. A collision
was improbable rather than impossible, and the odds grow with the square of the
site count: about 0.2% at a million sites, 18% at ten million. Site lookup takes
the first row it finds, so two sites sharing an id would file one customer's
events against the other's reports.

The constraint ships as drizzle migration `0015_parched_joshua_kane.sql` and is
applied automatically — `docker-entrypoint.sh` runs `npm run db:migrate` before
the server starts. Site creation now retries with fresh bytes when it hits that
constraint, and still reports a duplicate domain as `409`.

**Check for duplicates before deploying.** If any exist the migration fails, and
because the entrypoint runs it with `set -e`, the container will not start:

```sql
SELECT id, count(*) FROM sites GROUP BY id HAVING count(*) > 1;
```


## Taking a snapshot first

`pre-migration-snapshot.sh` captures a point-in-time copy of both databases.
This is the safety net for a one-off schema change; `ops/backups/` is the
scheduled, offsite one and is a different job.

```bash
ops/migrations/pre-migration-snapshot.sh create            # dump + checksums + manifest
ops/migrations/pre-migration-snapshot.sh verify  <dir>     # re-check the checksums
CONFIRM=1 ops/migrations/pre-migration-snapshot.sh restore <dir>
```

It dumps through the database engines rather than copying the Docker volumes:
`pg_dump -Fc` plus `pg_dumpall --globals-only` for Postgres, and per ClickHouse
table both `SHOW CREATE TABLE` and `SELECT ... FORMAT Native`. Keeping the
schema means a restore can rebuild an instance that has nothing in it, not just
refill tables that already exist.

The manifest counts the rows in each dump **file**, not in the table: asking the
table a second time is a different question, because a merge on a Replacing,
Aggregating or Summing table changes the answer with nobody writing, and the
restore would then report a mismatch although it reloaded every row it was
given. For those engines the manifest also records `count() FINAL`, which is
what a reload can actually reproduce - the raw rows collapse again as the
restored block is written. Postgres gets its own manifest of per-table row
counts, checked after `pg_restore`.

`restore` validates everything it needs before it changes anything: the files
it will read, a schema for every table it will have to create, and a dump for
every non-empty entry. A snapshot missing a piece is refused with nothing
touched, rather than discovered halfway through with Postgres already replaced.

One limit worth knowing: the Postgres dump is a single MVCC snapshot and is
consistent even under writes, while the ClickHouse tables are read one
statement at a time - each is consistent in itself, but they are not consistent
with each other. Stop ingestion if that matters.

Two things the snapshot does not carry: materialized view definitions (it skips
views, so after a full rebuild the app recreates them at startup), and any
guarantee about restoring into an instance where views are still attached -
they would double-write into their target tables as the rows arrive.

Restore overwrites the target, so it refuses to run without `CONFIRM=1` and
refuses to run over a database that still has tables unless `FORCE=1` as well.
Point `CH_DB`/`PG_DB` at scratch databases to rehearse a restore without
touching the live ones.


## What these scripts deliberately skip

Both the migration and the purge only touch tables in the MergeTree family. A
materialized view carries `site_id` too and shows up in `system.columns`
alongside real tables, but it cannot be rewritten or deleted from: the
migration would fail rewriting its `CREATE MATERIALIZED VIEW` statement, and
`DELETE FROM` is rejected outright. Their target tables are ordinary MergeTree
and are covered, which is where the rows actually live.

Both also skip `*__pre_uint32` and `*__u32`, so a rollback copy is never
rewritten, cleared, or counted twice.

The purge spares anything written in the last hour (`RECENT_GRACE`, matched
against whichever of `timestamp`, `event_hour`, `session_hour` or `start_time`
the table has). Orphans are historical by definition, while a site created
between reading the id list and running the delete would otherwise lose the
first events its owner is watching for. The id list is re-read before each
delete for the same reason.
