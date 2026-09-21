#!/usr/bin/env bash
#
# Take, verify and restore a point-in-time copy of a Rybbit instance's data.
#
# This is the safety net for a one-off schema change, not a backup schedule -
# ops/backups/ is the scheduled, offsite one. It dumps through the database
# engines rather than copying the Docker volumes, so the result is consistent
# even if something is still writing, and it can be restored into a different
# instance to rehearse.
#
#   ./pre-migration-snapshot.sh create   [DIR]   # dump, checksum, write a manifest
#   ./pre-migration-snapshot.sh verify   DIR     # re-check the checksums
#   ./pre-migration-snapshot.sh restore  DIR     # load it back (refuses without CONFIRM=1)
#
# Restore is deliberately awkward: it overwrites whatever is in the target
# instance, so it wants CONFIRM=1, and unless FORCE=1 is set as well it refuses
# an instance where either engine still holds tables - it counts tables, not
# rows, because an empty table is still someone's schema.
#
# Env:
#   CH_CONTAINER / PG_CONTAINER   container names (default: clickhouse / postgres)
#   CH_DB / PG_DB / PG_USER       names and role  (default: analytics / analytics / frog)
#   CONFIRM=1                     required by restore
#   FORCE=1                       allow restore over a database that has tables

set -euo pipefail

CH_CONTAINER="${CH_CONTAINER:-clickhouse}"
PG_CONTAINER="${PG_CONTAINER:-postgres}"
CH_DB="${CH_DB:-analytics}"
PG_DB="${PG_DB:-analytics}"
PG_USER="${PG_USER:-frog}"

ch()  { docker exec -i "$CH_CONTAINER" clickhouse-client --database "$CH_DB" "$@"; }
chq() { ch --query "$1"; }
# Restoring into an empty instance has to create the database first, and a
# client pointed at a database that does not exist cannot do that.
chq_nodb() { docker exec -i "$CH_CONTAINER" clickhouse-client --query "$1"; }

pg()  { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" "$@"; }
pgq() { pg -tAc "$1"; }

# One round trip for the row count of every base table in the public schema.
# query_to_xml runs the count per table inside the same statement, so this stays
# exact on a table that has no usable estimate, and adding a table to the app
# extends the manifest on its own.
PG_COUNT_SQL="
SELECT c.relname,
       (xpath('/row/cnt/text()',
              query_to_xml(format('select count(*) as cnt from public.%I', c.relname),
                           false, true, '')))[1]::text::bigint
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY c.relname"

pg_table_counts() { pg -tAF$'\t' -c "$PG_COUNT_SQL"; }

usage() { echo "usage: $0 create [dir] | verify <dir> | restore <dir>" >&2; exit 2; }

# Scratch space for bookkeeping that must not end up inside the snapshot, and
# must not survive an interrupted run either.
WORK=""
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; return 0; }
trap cleanup EXIT

ch_tables() {
  chq "SELECT name FROM system.tables
       WHERE database = '$CH_DB' AND engine NOT LIKE '%View' ORDER BY name"
}

# Engines that fold rows sharing a sort key into one. Their raw row count is not
# something a reload can reproduce: the dump carries every row as stored, but the
# rows come back in one block and the engine collapses them on the way in. What
# does survive is the count with FINAL - merging cannot change it - so that is
# the figure the restore is checked against.
collapses_rows() {
  case "$1" in
    *Replacing* | *Aggregating* | *Summing* | *Collapsing* | *Graphite*) return 0 ;;
    *) return 1 ;;
  esac
}

# How many rows the dump file actually holds. Asking the table a second time is
# not the same question: a merge on a Replacing, Aggregating or Summing table
# between the count and the dump changes the answer with nobody writing, and the
# restore then reports a mismatch although it reloaded every row it was given.
#
# So count the file, not the table. clickhouse-local reads the Native stream and
# infers its structure from the stream itself. The obvious alternative was
# system.query_log, but Rybbit's own deployment removes that table in its
# ClickHouse config, and a backup tool that only works when logging is on is not
# a backup tool.
dump_rows() {
  local file="$1" table="$2" rows
  # A table with no rows dumps to an empty stream. Native carries the column
  # names and types in the data itself, so there is nothing there to infer a
  # structure from and clickhouse-local refuses the file. No rows is the honest
  # answer, and an instance that has never recorded a session replay has four
  # such tables. The gzip header alone is tens of bytes, so only a file that
  # small is worth unpacking to check.
  if [ "$(stat -c%s "$file")" -lt 200 ] && [ "$(gzip -dc "$file" | wc -c)" -eq 0 ]; then
    echo 0
    return
  fi

  rows=$(gzip -dc "$file" |
    docker exec -i "$CH_CONTAINER" clickhouse-local --input-format Native \
      --query "SELECT count() FROM table") || {
    echo "Could not read back the dump of $table to count it." >&2
    exit 1
  }
  [ -n "$rows" ] || {
    echo "Counting the dump of $table produced no answer." >&2
    exit 1
  }
  echo "$rows"
}

cmd_create() {
  local dir="${1:-snapshot-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$dir/clickhouse"
  echo "Snapshot -> $dir"

  WORK=$(mktemp -d)

  echo "  postgres: database"
  docker exec -i "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$dir/postgres.dump"
  echo "  postgres: globals"
  docker exec -i "$PG_CONTAINER" pg_dumpall -U "$PG_USER" --globals-only > "$dir/postgres-globals.sql"
  # The manifest used to cover ClickHouse alone, so a restore could replace
  # Postgres with anything at all and still call itself a success.
  echo "  postgres: row counts"
  pg_table_counts > "$dir/postgres-manifest.tsv"

  local tables=()
  mapfile -t tables < <(ch_tables)

  local t engine
  for t in "${tables[@]}"; do
    echo "  clickhouse: $t"
    engine=$(chq "SELECT engine FROM system.tables
                  WHERE database = '$CH_DB' AND name = '$t'")
    # The schema travels with the rows. Without it a restore can only refill
    # tables that already exist, which rules out the case the snapshot is for:
    # rebuilding somewhere else, or after the schema itself went wrong.
    chq "SHOW CREATE TABLE \`$t\` FORMAT TSVRaw" > "$dir/clickhouse/$t.sql"
    ch --query "SELECT * FROM \`$t\` FORMAT Native" |
      gzip > "$dir/clickhouse/$t.native.gz"
    printf '%s\t%s\n' "$t" "$engine" >> "$WORK/tables.tsv"
  done

  : > "$dir/manifest.tsv"
  # Columns: table, rows in the dump, the count a restore is expected to
  # reproduce, engine. The first two are what older snapshots carry, so a
  # manifest written before this script grew the other two still restores.
  if [ -s "$WORK/tables.tsv" ]; then
    local rows check
    # fd 9, not stdin: dump_rows runs docker exec -i, which eats stdin.
    while IFS=$'\t' read -r -u 9 t engine; do
      rows=$(dump_rows "$dir/clickhouse/$t.native.gz" "$t")
      check="$rows"
      if collapses_rows "$engine"; then
        # A Replacing or Aggregating table folds duplicate keys as the restored
        # block is written, so the raw row count is not what comes back. The
        # count with FINAL is, and merging cannot change it.
        check=$(chq "SELECT count() FROM \`$t\` FINAL")
        echo "  dumped $t: $rows rows ($check after merging, $engine)"
      else
        echo "  dumped $t: $rows rows"
      fi
      printf '%s\t%s\t%s\t%s\n' "$t" "$rows" "$check" "$engine" >> "$dir/manifest.tsv"
    done 9< "$WORK/tables.tsv"
  fi

  # info.txt is written before the checksums are computed so that it is covered
  # by them: verify prints it, and an unchecksummed file it prints is a file it
  # cannot vouch for.
  {
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "clickhouse_version=$(chq 'SELECT version()')"
    echo "postgres_version=$(pgq 'show server_version')"
    echo "sites=$(pgq 'select count(*) from sites')"
    echo "site_id_seq=$(pgq 'select last_value from sites_site_id_seq')"
  } > "$dir/info.txt"

  # Checksum into a temporary file first: writing the list into the directory
  # being listed makes the result depend on when find happens to reach it. The
  # temporary goes to TMPDIR rather than the snapshot's parent, which is not
  # ours to write to and where an interrupted run used to leave litter.
  (cd "$dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum > "$WORK/checksums")
  mv "$WORK/checksums" "$dir/checksums.sha256"

  echo
  echo "Size: $(du -sh "$dir" | cut -f1)"
  echo "Verify it now:  $0 verify $dir"
}

cmd_verify() {
  local dir="$1"
  [ -f "$dir/checksums.sha256" ] || { echo "No checksums in $dir" >&2; exit 1; }
  (cd "$dir" && sha256sum -c --quiet checksums.sha256)
  echo "Checksums OK ($(wc -l < "$dir/checksums.sha256") files)"
  echo "Recorded row counts:"
  sed 's/^/  /' "$dir/manifest.tsv"
  if [ -f "$dir/postgres-manifest.tsv" ]; then
    echo "Recorded postgres row counts:"
    sed 's/^/  /' "$dir/postgres-manifest.tsv"
  fi
  cat "$dir/info.txt"
}

# Everything the restore is about to need, checked while the target is still
# untouched. The failure this exists for is a manifest entry whose dump was
# never written: it used to surface in the middle of the reload, with Postgres
# already replaced and some ClickHouse tables already truncated.
restore_preflight() {
  local dir="$1" bad=0 f t rows existing
  for f in manifest.tsv postgres.dump postgres-globals.sql; do
    [ -f "$dir/$f" ] || { echo "Snapshot has no $f" >&2; bad=1; }
  done
  # A snapshot from before this script recorded Postgres row counts still
  # restores - refusing it would be worst at the moment it is needed - but say
  # plainly that the Postgres side comes back unchecked.
  [ -f "$dir/postgres-manifest.tsv" ] ||
    echo "Note: this snapshot has no postgres-manifest.tsv, so Postgres cannot be verified." >&2
  [ "$bad" = "0" ] || { echo "Refusing to restore: nothing has been changed." >&2; exit 1; }

  existing=$(chq_nodb "SELECT name FROM system.tables WHERE database = '$CH_DB'")
  while IFS=$'\t' read -r -u 9 t rows _; do
    case "$rows" in
      '' | *[!0-9]*)
        echo "Manifest row count for $t is not a number: '$rows'" >&2
        bad=1
        continue
        ;;
    esac
    if [ "$rows" != "0" ] && [ ! -r "$dir/clickhouse/$t.native.gz" ]; then
      echo "Manifest wants $rows rows for $t but $t.native.gz is missing" >&2
      bad=1
    fi
    if ! printf '%s\n' "$existing" | grep -qxF -- "$t" && [ ! -f "$dir/clickhouse/$t.sql" ]; then
      echo "Snapshot has no schema for $t and the table does not exist" >&2
      bad=1
    fi
  done 9< "$dir/manifest.tsv"
  [ "$bad" = "0" ] || { echo "Refusing to restore: nothing has been changed." >&2; exit 1; }
}

cmd_restore() {
  local dir="$1"
  [ "${CONFIRM:-0}" = "1" ] || {
    echo "Refusing to restore without CONFIRM=1: this overwrites $PG_CONTAINER and $CH_CONTAINER." >&2
    exit 1
  }
  cmd_verify "$dir" > /dev/null

  # The guard used to look at Postgres alone, which let a restore walk into an
  # instance whose Postgres happened to be empty and truncate a full ClickHouse
  # beside it.
  local pg_tables ch_tables_now
  pg_tables=$(pgq "select count(*) from information_schema.tables where table_schema='public'" |
    tr -d ' ')
  ch_tables_now=$(chq_nodb "SELECT count() FROM system.tables WHERE database = '$CH_DB'")
  if [ "$pg_tables" != "0" ] || [ "$ch_tables_now" != "0" ]; then
    if [ "${FORCE:-0}" != "1" ]; then
      echo "Target is not empty: Postgres has $pg_tables tables, ClickHouse $ch_tables_now." >&2
      echo "Re-run with FORCE=1 to overwrite them." >&2
      exit 1
    fi
  fi

  restore_preflight "$dir"

  WORK=$(mktemp -d)

  echo "Restoring postgres globals"
  docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres < "$dir/postgres-globals.sql" > /dev/null 2>&1 || true
  echo "Restoring postgres database"
  docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$PG_DB" --clean --if-exists --no-owner \
    < "$dir/postgres.dump" > /dev/null

  chq_nodb "CREATE DATABASE IF NOT EXISTS \`$CH_DB\`"
  # Read the manifest on fd 9: every helper here runs `docker exec -i`, which
  # consumes stdin. On fd 0 the first TRUNCATE swallows the rest of the file and
  # the loop ends after one table - with the restore reporting success.
  local t rows check engine now
  while IFS=$'\t' read -r -u 9 t rows check engine; do
    # A manifest from before the extra columns only knows the dumped count.
    [ -n "$check" ] || check="$rows"
    echo "Restoring clickhouse: $t ($rows rows)"

    if [ -z "$(chq "SELECT name FROM system.tables WHERE database = currentDatabase() AND name = '$t'")" ]; then
      echo "  creating $t from the snapshot's schema"
      sed "s/^CREATE \\(TABLE\\|MATERIALIZED VIEW\\) [^ .]*\\./CREATE \\1 $CH_DB./" "$dir/clickhouse/$t.sql" | ch
    fi

    chq "TRUNCATE TABLE IF EXISTS \`$t\`" > /dev/null 2>&1 || true
    # A Native dump of an empty table carries only the header, and ClickHouse
    # rejects that insert with NO_DATA_TO_INSERT. Truncating is the whole job.
    if [ "$rows" != "0" ]; then
      gzip -dc "$dir/clickhouse/$t.native.gz" | ch --query "INSERT INTO \`$t\` FORMAT Native"
    fi
    if collapses_rows "$engine"; then
      now=$(chq "SELECT count() FROM \`$t\` FINAL")
    else
      now=$(chq "SELECT count() FROM \`$t\`")
    fi
    printf '%s\t%s\t%s\n' "$t" "$check" "$now" >> "$WORK/restored.tsv"
  done 9< "$dir/manifest.tsv"

  local bad=0
  echo
  echo "Row counts after restore:"
  if [ -s "$WORK/restored.tsv" ]; then
    while IFS=$'\t' read -r -u 9 t check now; do
      if [ "$now" = "$check" ]; then
        echo "  $t: $now"
      else
        echo "  $t: $now (expected $check) MISMATCH"
        bad=1
      fi
    done 9< "$WORK/restored.tsv"
  fi

  echo
  if [ ! -f "$dir/postgres-manifest.tsv" ]; then
    echo "Postgres was restored but this snapshot records no row counts to check it against."
    [ "$bad" = "0" ] || { echo "Restore did not reproduce the snapshot." >&2; exit 1; }
    echo
    echo "Restore matches the snapshot's ClickHouse tables."
    return 0
  fi
  echo "Postgres row counts after restore:"
  pg_table_counts > "$WORK/pg-now.tsv"
  while IFS=$'\t' read -r -u 9 t rows; do
    now=$(awk -F'\t' -v t="$t" '$1 == t { print $2 }' "$WORK/pg-now.tsv")
    if [ "$now" = "$rows" ]; then
      echo "  $t: $now"
    elif [ -z "$now" ]; then
      echo "  $t: table is missing (expected $rows rows) MISMATCH"
      bad=1
    else
      echo "  $t: $now (expected $rows) MISMATCH"
      bad=1
    fi
  done 9< "$dir/postgres-manifest.tsv"
  # A table the snapshot never had means the target was not the instance this
  # snapshot describes, or FORCE=1 papered over leftovers.
  while IFS=$'\t' read -r -u 9 t now; do
    if ! cut -f1 "$dir/postgres-manifest.tsv" | grep -qxF -- "$t"; then
      echo "  $t: $now (not in the snapshot) MISMATCH"
      bad=1
    fi
  done 9< "$WORK/pg-now.tsv"

  [ "$bad" = "0" ] || { echo "Restore did not reproduce the snapshot." >&2; exit 1; }
  echo
  echo "Restore matches the snapshot."
}

case "${1:-}" in
  create)  shift; cmd_create "${1:-}" ;;
  verify)  shift; [ $# -ge 1 ] || usage; cmd_verify "$1" ;;
  restore) shift; [ $# -ge 1 ] || usage; cmd_restore "$1" ;;
  *) usage ;;
esac
