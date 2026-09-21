#!/usr/bin/env bash
#
# Widen site_id from UInt16 to UInt32 in every ClickHouse table that carries it.
#
# Why: sites.site_id in Postgres is a serial (int4) that never reuses a number,
# while the ClickHouse tables declared site_id as UInt16, which stops at 65535.
# ClickHouse does not reject an id past that - it stores the value modulo 65536,
# so site 70000's events are filed under site 4464 and show up in that
# customer's reports. Nothing is logged and the tracker answers success.
#
# The column is part of ORDER BY (site_id, timestamp), and ClickHouse refuses
# ALTER ... MODIFY COLUMN on a key column, so each table is recreated and
# swapped in with EXCHANGE TABLES (atomic, requires an Atomic database).
#
# Stop event ingestion before running this: rows written to the old table
# between the copy and the swap would be lost. The run re-reads the table after
# the copy and refuses to swap if it grew, so a writer that was left running is
# reported rather than trusted, but the check costs a failed migration - stop
# the writers first.
#
#   docker compose stop backend
#   ./2026-09-21-site-id-uint32.sh
#   docker compose start backend
#
# The pre-migration copy of each table is kept as <table>__pre_uint32 so the
# swap can be undone while the new one is being checked:
#
#   EXCHANGE TABLES events AND events__pre_uint32
#
# Drop those once the instance has been running on UInt32 long enough to trust
# it - DROP_OLD=1 does it during the run instead, which leaves no way back.
#
# Env:
#   CH_CONTAINER  ClickHouse container name   (default: clickhouse)
#   CH_DB         database                    (default: analytics)
#   DRY_RUN       print the plan, change nothing (default: 0)
#   DROP_OLD      discard the pre-migration copy immediately (default: 0)

set -euo pipefail

CH_CONTAINER="${CH_CONTAINER:-clickhouse}"
CH_DB="${CH_DB:-analytics}"
DRY_RUN="${DRY_RUN:-0}"
DROP_OLD="${DROP_OLD:-0}"
SUFFIX="__u32"
KEPT_SUFFIX="__pre_uint32"

ch() { docker exec -i "$CH_CONTAINER" clickhouse-client --database "$CH_DB" "$@"; }
q()  { ch --query "$1"; }

# Copy the rows a day at a time when the table is timestamped.
#
# A single INSERT ... SELECT is the obvious way and it is what this did first.
# It does not survive a small box: ClickHouse on a 4 GB machine caps its own
# memory near 1 GiB and already holds most of it, so copying a table of a
# million rows - and even one month of one - dies with MEMORY_LIMIT_EXCEEDED
# partway through. Nothing is lost when that happens (the swap has not run yet),
# but the migration stops with a half-filled copy to clean up.
#
# A day is small enough everywhere this runs, and capping threads and block size
# keeps the peak flat rather than proportional to the slice.
SETTINGS="SETTINGS max_threads = 1, max_insert_threads = 1, max_block_size = 8192"

# Not every table calls its time column `timestamp`: the hourly aggregates use
# event_hour, the session ones start_time or session_hour. Slice by whichever
# one the table has, so the memory bound covers those tables too instead of
# leaving them to a single unbounded INSERT.
#
# Asking system.columns also separates the two things the old code could not
# tell apart. A table with no time column answers with an empty result; a
# memory limit, a timeout or a dead container fails the query, and with no
# `|| true` to swallow it the run stops there.
time_column() {
  q "SELECT name FROM system.columns
     WHERE database = '$CH_DB' AND table = '$1'
       AND name IN ('timestamp', 'event_hour', 'session_hour', 'start_time')
     ORDER BY name LIMIT 1 $SETTINGS"
}

days_of() {
  q "SELECT DISTINCT toDate(\`$2\`) AS d FROM \`$1\` ORDER BY d $SETTINGS FORMAT TSV"
}

copy_rows() {
  local from="$1" to="$2" col="$3" days="$4" day

  if [ -z "$col" ]; then
    echo "    no time column on this table: copying in one statement"
    q "INSERT INTO \`$to\` SELECT * FROM \`$from\` $SETTINGS"
    return
  fi

  echo "    copying by $col, $(printf '%s' "$days" | grep -c . || true) day(s)"
  for day in $days; do
    q "INSERT INTO \`$to\` SELECT * FROM \`$from\` WHERE toDate(\`$col\`) = '$day' $SETTINGS"
  done
}

# Counting rows straight off each table is wrong for the collapsing engines.
# ReplacingMergeTree, SummingMergeTree and AggregatingMergeTree merge rows with
# equal sort keys while the part is written, so the fresh copy legitimately
# holds fewer rows than the source it was read from - session_replay_metadata
# drops from 180 to 60 - and the old check read that as data loss and refused
# to swap. FINAL applies the same collapsing to both sides. Plain MergeTree
# rejects FINAL outright, so only ask for it where the engine collapses.
final_clause() {
  case "$1" in
    *Replacing*|*Summing*|*Aggregating*|*Collapsing*|*Graphite*) echo "FINAL" ;;
    *) echo "" ;;
  esac
}

rows_in() { q "SELECT count() FROM \`$1\` ${2:-} $SETTINGS"; }

db_engine=$(q "SELECT engine FROM system.databases WHERE name = '$CH_DB'")
if [ "$db_engine" != "Atomic" ]; then
  echo "ERROR: database '$CH_DB' uses engine '$db_engine'; EXCHANGE TABLES needs Atomic." >&2
  exit 1
fi

# EXCHANGE TABLES and the RENAME that parks the original are two statements. A
# run killed between them leaves the live table already UInt32 with its
# pre-migration rows still under the copy's name and no <table>__pre_uint32 to
# roll back to. Nothing further down would notice - the live table no longer
# matches the UInt16 filter and the copy is excluded by name - so the next run
# would report that there is nothing to do and exit 0.
leftovers=$(q "SELECT name FROM system.tables
               WHERE database = '$CH_DB' AND endsWith(name, '$SUFFIX') ORDER BY name")
for tmp in $leftovers; do
  t="${tmp%"$SUFFIX"}"
  live_type=$(q "SELECT type FROM system.columns
                 WHERE database = '$CH_DB' AND table = '$t' AND name = 'site_id'")
  # Still UInt16, or gone: the copy died before the swap, and the per-table
  # guard further down reports that case with its own row count.
  [ "$live_type" = "UInt32" ] || continue

  echo "ERROR: $t already has a UInt32 site_id but $tmp still holds its pre-migration" >&2
  echo "       rows, so an earlier run was interrupted between the swap and the rename." >&2
  echo "       The migration itself is done; $tmp holds $(rows_in "$tmp") rows. Finish it:" >&2
  if [ -n "$(q "SELECT name FROM system.tables
                WHERE database = '$CH_DB' AND name = '${t}${KEPT_SUFFIX}'")" ]; then
    echo "       ${t}${KEPT_SUFFIX} exists too - decide which copy to keep, drop the other." >&2
  else
    echo "         RENAME TABLE $tmp TO ${t}${KEPT_SUFFIX}" >&2
    echo "       or DROP TABLE $tmp if the pre-migration rows are no longer wanted." >&2
  fi
  exit 1
done

# A kept pre-migration copy still has a UInt16 site_id, so it would otherwise
# look like a table that needs migrating on the next run.
# Match those two suffixes with endsWith, not LIKE: `_` is a single-character
# wildcard there, so '%__u32' also matches an ordinary table called
# pageviews_u32 and would quietly leave it out of the migration.
# Materialized views appear in system.columns next to real tables, but SHOW
# CREATE returns CREATE MATERIALIZED VIEW, which this cannot rewrite or swap -
# and the run would die on the first one, halfway through, with ingestion
# already stopped. Their target tables are ordinary MergeTree and are covered.
tables=$(q "SELECT c.table FROM system.columns c
            INNER JOIN system.tables t ON t.database = c.database AND t.name = c.table
            WHERE c.database = '$CH_DB' AND c.name = 'site_id' AND c.type = 'UInt16'
              AND t.engine LIKE '%MergeTree'
              AND NOT endsWith(c.table, '$KEPT_SUFFIX')
              AND NOT endsWith(c.table, '$SUFFIX')
            ORDER BY c.table")

if [ -z "$tables" ]; then
  echo "Nothing to do: no table in '$CH_DB' has a UInt16 site_id."
  exit 0
fi

echo "Tables to migrate:"
while read -r line; do echo "  - $line"; done <<< "$tables"
[ "$DRY_RUN" = "1" ] && { echo "DRY_RUN=1, stopping here."; exit 0; }

for t in $tables; do
  tmp="${t}${SUFFIX}"
  echo "==> $t"

  if [ -n "$(q "SELECT name FROM system.tables WHERE database = '$CH_DB' AND name = '$tmp'")" ]; then
    echo "ERROR: $tmp already exists - a previous run left it behind." >&2
    echo "       It holds $(rows_in "$tmp") rows. Inspect it, then drop it and re-run." >&2
    exit 1
  fi

  # A previous run may have swapped this table and died before parking the
  # original, or an operator may have rolled back with EXCHANGE TABLES. Either
  # way the copy already holds real rows, and overwriting it destroys the only
  # way back.
  kept="${t}${KEPT_SUFFIX}"
  if [ -n "$(q "SELECT name FROM system.tables WHERE database = '$CH_DB' AND name = '$kept'")" ]; then
    echo "ERROR: $kept already exists and holds $(rows_in "$kept") rows." >&2
    echo "       That is a rollback target from an earlier run. Decide what to keep, drop it, then re-run." >&2
    exit 1
  fi

  final=$(final_clause "$(q "SELECT engine FROM system.tables
                             WHERE database = '$CH_DB' AND name = '$t'")")
  before=$(rows_in "$t" "$final")
  time_col=$(time_column "$t")
  days=""
  [ -n "$time_col" ] && days=$(days_of "$t" "$time_col")

  # Reuse the live DDL so engine, partitioning, TTL and indexes carry over
  # untouched; only the site_id type and the table name are rewritten.
  ddl=$(q "SHOW CREATE TABLE $t FORMAT TSVRaw" | sed \
    -e "s/^CREATE TABLE ${CH_DB}\.${t}\$/CREATE TABLE ${CH_DB}.${tmp}/" \
    -e "s/\`site_id\` UInt16/\`site_id\` UInt32/")

  case "$ddl" in
    *"${CH_DB}.${tmp}"*) : ;;
    *) echo "ERROR: could not rewrite the CREATE statement for $t." >&2; exit 1 ;;
  esac

  echo "$ddl" | ch

  # A TTL is applied as the copy is written, so rows the source is still
  # holding past their expiry - anything the source's own TTL merge has not
  # got to yet - are dropped on the way in and the two counts disagree over
  # rows that were never lost. Hold the copy's TTL merges off until it has
  # been verified, then let them run: it expires exactly as the source would.
  q "SYSTEM STOP TTL MERGES \`$CH_DB\`.\`$tmp\`"

  copy_rows "$t" "$tmp" "$time_col" "$days"

  # Both $days and $before were read before the copy started, so a row written
  # afterwards is in neither and the counts below would agree while the swap
  # threw it away. Crossing UTC midnight during a long copy is the easy way in:
  # the new day is not in the list at all, so not one of its rows is copied.
  # Shrinking is fine - a merge or a TTL on the source can do that, and the
  # copy simply carries a row the source has since dropped.
  if [ -n "$time_col" ]; then
    new_days=$(comm -13 <(printf '%s\n' "$days") <(days_of "$t" "$time_col"))
    if [ -n "$new_days" ]; then
      echo "ERROR: $t gained a day while it was being copied:" >&2
      echo "       $(echo "$new_days" | paste -sd' ' -)" >&2
      echo "       None of those rows are in $tmp. Ingestion is still running;" >&2
      echo "       stop it, drop $tmp and re-run." >&2
      exit 1
    fi
  fi

  grown=$(rows_in "$t" "$final")
  if [ "$grown" -gt "$before" ]; then
    echo "ERROR: $t grew from $before to $grown rows while it was being copied." >&2
    echo "       Ingestion is still running; stop it, drop $tmp and re-run." >&2
    exit 1
  fi

  after=$(rows_in "$tmp" "$final")
  if [ "$before" != "$after" ]; then
    echo "ERROR: $t had $before rows, $tmp has $after. Not swapping; drop $tmp and retry." >&2
    exit 1
  fi

  q "SYSTEM START TTL MERGES \`$CH_DB\`.\`$tmp\`"
  q "EXCHANGE TABLES $t AND $tmp"

  # After the swap $tmp holds the pre-migration rows.
  if [ "$DROP_OLD" = "1" ]; then
    q "DROP TABLE $tmp"
  else
    # $kept was proven absent above, so this never overwrites a rollback target.
    q "RENAME TABLE $tmp TO $kept"
  fi

  echo "    $before rows, site_id now $(q "SELECT type FROM system.columns WHERE database = '$CH_DB' AND table = '$t' AND name = 'site_id'")"
done

echo
echo "Done. Deploy the matching image: its queries bind site ids as UInt32."

if [ "$DROP_OLD" != "1" ]; then
  echo
  echo "The pre-migration tables are kept. To undo a table:"
  echo "  EXCHANGE TABLES <table> AND <table>${KEPT_SUFFIX}"
  echo "To discard them once you are satisfied:"
  echo "  DROP TABLE <table>${KEPT_SUFFIX}"
fi
