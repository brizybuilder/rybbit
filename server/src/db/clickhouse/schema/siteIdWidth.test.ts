import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// site_id is UInt32 on purpose: Postgres hands out ids from a serial that never
// reuses a number, and ClickHouse does not reject an out-of-range id - it stores
// it modulo the column width, so a UInt16 column silently files site 70000's
// events under site 4464 and shows them in that customer's reports.
//
// The width has to match in two places at once: the DDL that creates the tables,
// and every query that binds a site id as a parameter. This guards both, because
// an upstream merge that narrows either one produces no error at all - only
// wrong numbers in someone else's dashboard.
//
// Both checks key off the column name in the SQL rather than off the parameter's
// name. Parameter names are not a reliable handle: this codebase already binds a
// site id as {site:Int32}, {newSites:Array(Int32)} and
// {grandfatheredSites:Array(Int32)}, none of which contain "siteId".

const SERVER_SRC = join(import.meta.dirname, "..", "..", "..");
const THIS_FILE = "siteIdWidth.test.ts";

// Anything narrower than 32 bits truncates a site id. Signed Int32 is tolerated:
// Postgres serial is int4, so it cannot produce a value Int32 cannot hold.
const NARROW = String.raw`U?Int(?:8|16)\b`;

// `site_id` UInt16 / site_id Nullable(UInt16) / site_id SimpleAggregateFunction(max, UInt16)
const DDL = new RegExp(String.raw`\x60?site_id\x60?\s+(?:\w+\(\s*(?:\w+\s*,\s*)?)?${NARROW}`);

// site_id = {site:UInt16} / site_id IN {newSites:Array(UInt16)}
const BINDING = new RegExp(String.raw`site_id[^\n]{0,60}\{[^}\n]*:\s*(?:Array\(\s*)?${NARROW}`);

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap(entry => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return entry === "node_modules" ? [] : walk(path);
    return /\.(ts|sql)$/.test(entry) && entry !== THIS_FILE ? [path] : [];
  });
}

describe("site_id column width", () => {
  const files = walk(SERVER_SRC).map(path => [path, readFileSync(path, "utf8")] as const);

  it("declares site_id at 32 bits in every table definition", () => {
    expect(files.filter(([, source]) => DDL.test(source)).map(([path]) => path)).toEqual([]);
  });

  it("binds site id query parameters at 32 bits", () => {
    expect(files.filter(([, source]) => BINDING.test(source)).map(([path]) => path)).toEqual([]);
  });

  it("catches the spellings this codebase actually uses", () => {
    const narrow = [
      "site_id UInt16,",
      "`site_id` UInt16,",
      "site_id Nullable(UInt16),",
      "site_id SimpleAggregateFunction(max, UInt16),",
      "site_id UInt8,",
    ];
    const bindings = [
      "site_id = {site:UInt16}",
      "site_id IN {newSites:Array(UInt16)}",
      "site_id IN {grandfatheredSites:Array( UInt16 )}",
      "site_id = {siteId:Int16}",
      "WHERE site_id IN {siteIds:Array(UInt8)}",
    ];
    const wide = [
      "site_id UInt32,",
      "`site_id` UInt32,",
      "site_id = {site:Int32}",
      "site_id IN {siteIds:Array(UInt32)}",
      "screen_width UInt16,",
      "INTERVAL {days: UInt16} DAY",
    ];

    expect(narrow.filter(sample => !DDL.test(sample))).toEqual([]);
    expect(bindings.filter(sample => !BINDING.test(sample))).toEqual([]);
    expect(wide.filter(sample => DDL.test(sample) || BINDING.test(sample))).toEqual([]);
  });
});
