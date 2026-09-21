#!/usr/bin/env bash
#
# Delete ClickHouse rows whose site no longer exists in Postgres.
#
# Until the fix that ships alongside this script, deleting a site only cleared
# the two session-replay tables; its pageviews, bot events and observations
# stayed behind for good. Those rows are invisible in the product - every report
# is scoped to a site that exists - but they are a loaded gun: hand that id to a
# new site, by reusing a number or resetting the sequence, and the new owner
# inherits a stranger's history and sees it as their own.
#
# Postgres is the source of truth here. Anything in ClickHouse carrying a
# site_id with no matching sites row is orphaned and removed.
#
# Runs as a dry run unless told otherwise, because it deletes:
#
#   ./2026-09-21-purge-orphaned-site-data.sh              # report only
#   APPLY=1 ./2026-09-21-purge-orphaned-site-data.sh      # actually delete
#
# Env:
#   CH_CONTAINER  ClickHouse container  (default: clickhouse)
#   PG_CONTAINER  Postgres container    (default: postgres)
#   CH_DB / PG_DB database names        (default: analytics / analytics)
#   PG_USER       Postgres role         (default: frog)
#   APPLY         1 to delete           (default: 0, report only)

set -euo pipefail

CH_CONTAINER="${CH_CONTAINER:-clickhouse}"
PG_CONTAINER="${PG_CONTAINER:-postgres}"
CH_DB="${CH_DB:-analytics}"
PG_DB="${PG_DB:-analytics}"
PG_USER="${PG_USER:-frog}"
APPLY="${APPLY:-0}"

ch() { docker exec -i "$CH_CONTAINER" clickhouse-client --database "$CH_DB" --query "$1"; }
pg() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }

# Leave the pre-migration copies alone: they are a rollback target and should
# stay exactly as they were captured.
# Only the MergeTree family accepts a DELETE. A materialized view also carries
# site_id and would both double-count the dry run (it reads its target table)
# and fail the delete, stopping the loop with some tables cleaned and some not.
# Read the list into an array rather than splitting a string: a table name is
# allowed to contain a space, and one that did would arrive here as two names
# that match nothing.
mapfile -t tables < <(ch "SELECT c.table FROM system.columns c
             INNER JOIN system.tables t ON t.database = c.database AND t.name = c.table
             WHERE c.database = '$CH_DB' AND c.name = 'site_id'
               AND t.engine LIKE '%MergeTree'
               -- endsWith, not LIKE: underscore matches any single character in
               -- LIKE, so '%__u32' would also exclude a table named pageviews_u32.
               AND NOT endsWith(c.table, '__pre_uint32') AND NOT endsWith(c.table, '__u32')
             ORDER BY c.table")

read_live_ids() { pg "SELECT site_id FROM sites ORDER BY site_id" | tr -d ' ' | paste -sd, -; }

live=$(read_live_ids)
if [ -z "$live" ]; then
  echo "Refusing to run: Postgres reports no sites at all, which is more likely a" >&2
  echo "connection problem than an empty instance. Nothing was deleted." >&2
  exit 1
fi

# The id list travels as a single argv entry, and the kernel caps one at 128 KiB
# (ClickHouse caps the query itself at 256 KiB by default). Roughly 20k sites is
# where that bites - which is precisely the size of instance this migration
# exists for. Fail with the reason rather than an opaque "Argument list too long".
if [ "${#live}" -gt 100000 ]; then
  echo "Refusing to run: the site id list is ${#live} bytes, too close to the limit on a" >&2
  echo "single command argument. This script needs rewriting to stream ids instead." >&2
  exit 1
fi

# Orphans are historical by definition. Sparing anything recent keeps a site
# created after the id list was read from losing its first events - the exact
# moment its owner is watching for them.
RECENT_GRACE="${RECENT_GRACE:-1 HOUR}"

total=0
for t in "${tables[@]}"; do
  # Tables that record when a row arrived can spare the recent ones; the rest
  # are matched on the site id alone.
  # Not every table calls it `timestamp`: the hourly aggregates use event_hour,
  # the session ones start_time or session_hour. Take whichever exists so the
  # grace window covers those too, instead of only the raw event tables.
  time_col=$(ch "SELECT name FROM system.columns
                 WHERE database = '$CH_DB' AND table = '$t'
                   AND name IN ('timestamp', 'event_hour', 'session_hour', 'start_time')
                 ORDER BY name LIMIT 1")
  if [ -n "$time_col" ]; then
    where="site_id NOT IN ($live) AND $time_col < now() - INTERVAL $RECENT_GRACE"
  else
    where="site_id NOT IN ($live)"
  fi

  orphans=$(ch "SELECT count() FROM \`$t\` WHERE $where")
  [ "$orphans" = "0" ] && continue
  ids=$(ch "SELECT DISTINCT site_id FROM \`$t\` WHERE $where
            ORDER BY site_id LIMIT 20" | paste -sd, -)

  total=$((total + orphans))
  echo "$t: $orphans orphaned rows (site ids: ${ids:-none})"

  if [ "$APPLY" = "1" ]; then
    # Re-read the ids and rebuild the condition with them: a site created while
    # this loop was running is live now even though it was not when the list was
    # taken, and deleting on the stale list would take its rows.
    live=$(read_live_ids)
    [ -n "$live" ] || { echo "Postgres stopped answering mid-run; stopping." >&2; exit 1; }
    if [ -n "$time_col" ]; then
      where="site_id NOT IN ($live) AND $time_col < now() - INTERVAL $RECENT_GRACE"
    else
      where="site_id NOT IN ($live)"
    fi
    ch "DELETE FROM \`$t\` WHERE $where"
    echo "  deleted"
  fi
done

if [ "$total" = "0" ]; then
  echo "No orphaned rows: every site_id in ClickHouse has a site in Postgres."
elif [ "$APPLY" != "1" ]; then
  echo
  echo "$total rows would be deleted. Re-run with APPLY=1 to do it."
fi
