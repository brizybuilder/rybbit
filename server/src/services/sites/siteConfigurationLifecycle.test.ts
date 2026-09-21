import { beforeEach, describe, expect, it, vi } from "vitest";

const state = vi.hoisted(() => ({
  site: null as Record<string, unknown> | null,
  updateError: null as Error | null,
  deleteError: null as Error | null,
  updates: [] as Record<string, unknown>[],
  deletes: 0,
  siteIdTables: ["bot_events", "events", "session_replay_events"] as string[],
  insertErrors: [] as unknown[],
  insertedValues: [] as Record<string, unknown>[],
}));

const mocks = vi.hoisted(() => ({
  clickhouseCommand: vi.fn(),
  clickhouseQuery: vi.fn(),
  insert: vi.fn(),
  invalidate: vi.fn(),
  getConfig: vi.fn(),
}));

vi.mock("../../db/postgres/postgres.js", () => ({
  db: {
    query: {
      sites: {
        findFirst: vi.fn(async () => state.site),
      },
    },
    update: vi.fn(() => ({
      set: (data: Record<string, unknown>) => ({
        where: async () => {
          if (state.updateError) throw state.updateError;
          state.updates.push(data);
        },
      }),
    })),
    delete: vi.fn(() => ({
      where: async () => {
        if (state.deleteError) throw state.deleteError;
        state.deletes += 1;
      },
    })),
    insert: mocks.insert,
  },
}));

vi.mock("../../db/clickhouse/clickhouse.js", () => ({
  clickhouse: { command: mocks.clickhouseCommand, query: mocks.clickhouseQuery },
}));

// createUnclaimed() inserts straight through db; the retry wrapper is what this
// exercises, so the insert is driven by a queue of failures the test supplies.
vi.mock("./withOrganizationSiteLock.js", () => ({
  withOrganizationSiteLock: vi.fn(async (_org: string, run: (tx: unknown) => Promise<unknown>) =>
    run({ insert: mocks.insert })
  ),
}));

vi.mock("../../lib/siteConfig.js", () => ({
  siteConfig: { invalidate: mocks.invalidate, getConfig: mocks.getConfig },
}));

vi.mock("../../api/stripe/getSubscription.js", () => ({
  getSubscriptionInner: vi.fn(),
}));

import { siteConfigurationLifecycle } from "./siteConfigurationLifecycle.js";

function makeSite() {
  return {
    siteId: 1,
    id: "abcdef123456",
    type: null,
    domain: "example.com",
    organizationId: "org_1",
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  state.site = makeSite();
  state.updateError = null;
  state.deleteError = null;
  state.updates.length = 0;
  state.deletes = 0;
  state.siteIdTables = ["bot_events", "events", "session_replay_events"];
  state.insertErrors.length = 0;
  state.insertedValues.length = 0;
  mocks.clickhouseCommand.mockResolvedValue(undefined);
  mocks.clickhouseQuery.mockImplementation(async () => ({
    json: async () => state.siteIdTables.map(table => ({ table })),
  }));
  mocks.insert.mockImplementation(() => ({
    values: (values: Record<string, unknown>) => ({
      returning: async () => {
        state.insertedValues.push(values);
        const failure = state.insertErrors.shift();
        if (failure) throw failure;
        return [{ siteId: 1, ...values }];
      },
    }),
  }));
  mocks.getConfig.mockResolvedValue({ siteId: 1, id: "abcdef123456", name: "Renamed" });
});

describe("siteConfigurationLifecycle", () => {
  it("updates persistence once, invalidates the Site, and reloads its configuration", async () => {
    const result = await siteConfigurationLifecycle.update(1, { name: "Renamed" });

    expect(state.updates).toHaveLength(1);
    expect(state.updates[0]).toMatchObject({ name: "Renamed" });
    expect(mocks.invalidate).toHaveBeenCalledOnce();
    expect(mocks.invalidate).toHaveBeenCalledWith(state.site);
    expect(mocks.getConfig).toHaveBeenCalledWith(1);
    expect(result).toMatchObject({ name: "Renamed" });
  });

  it("propagates persistence failures without invalidating the cache", async () => {
    state.updateError = new Error("postgres unavailable");

    await expect(siteConfigurationLifecycle.update(1, { name: "Renamed" })).rejects.toThrow("postgres unavailable");

    expect(mocks.invalidate).not.toHaveBeenCalled();
    expect(mocks.getConfig).not.toHaveBeenCalled();
  });

  it("owns private-link persistence and invalidation", async () => {
    const privateLinkKey = await siteConfigurationLifecycle.updatePrivateLink(1, "generate_private_link_key");

    expect(privateLinkKey).toMatch(/^[a-f0-9]{12}$/);
    expect(state.updates).toEqual([{ privateLinkKey }]);
    expect(mocks.invalidate).toHaveBeenCalledWith(state.site);
  });

  it("clears every table holding site_id before the Site row, not just the replay ones", async () => {
    state.siteIdTables = ["bot_events", "bot_observations", "events", "session_replay_metadata"];

    await siteConfigurationLifecycle.delete(1);

    const cleared = mocks.clickhouseCommand.mock.calls.map(([call]) => call.query);
    expect(cleared).toHaveLength(4);
    for (const table of state.siteIdTables) {
      expect(cleared.some((query: string) => query.includes(`DELETE FROM ${table} `))).toBe(true);
    }
    expect(state.deletes).toBe(1);
    expect(mocks.invalidate).toHaveBeenCalledWith(state.site);
  });

  it("asks only for tables a DELETE can reach, and leaves rollback copies alone", async () => {
    await siteConfigurationLifecycle.delete(1);

    const [{ query }] = mocks.clickhouseQuery.mock.calls[0];
    // A materialized view carries site_id but rejects DELETE, and a
    // <table>__pre_uint32 copy is somebody's way back from a migration.
    expect(query).toContain("engine LIKE '%MergeTree'");
    expect(query).toContain("__pre_uint32");
    expect(query).toContain("__u32");
  });

  it("drops a rollback copy from the list even if the query stops filtering it", async () => {
    state.siteIdTables = ["events", "events__pre_uint32", "bot_events__u32"];

    await siteConfigurationLifecycle.delete(1);

    const cleared = mocks.clickhouseCommand.mock.calls.map(([call]) => call.query);
    expect(cleared).toHaveLength(1);
    expect(cleared[0]).toContain("DELETE FROM events ");
  });

  it("asks ClickHouse which tables carry site_id instead of assuming a list", async () => {
    state.siteIdTables = ["events", "a_table_added_upstream"];

    await siteConfigurationLifecycle.delete(1);

    expect(mocks.clickhouseQuery).toHaveBeenCalledOnce();
    const cleared = mocks.clickhouseCommand.mock.calls.map(([call]) => call.query);
    expect(cleared.some((query: string) => query.includes("a_table_added_upstream"))).toBe(true);
  });

  it("does not report deletion when event cleanup fails", async () => {
    mocks.clickhouseCommand.mockRejectedValueOnce(new Error("clickhouse unavailable"));

    await expect(siteConfigurationLifecycle.delete(1)).rejects.toThrow("clickhouse unavailable");

    expect(state.deletes).toBe(0);
    expect(mocks.invalidate).not.toHaveBeenCalled();
  });

  it("retries with a fresh public id when the generated one collides", async () => {
    state.insertErrors = [{ code: "23505", constraint_name: "sites_id_unique" }];

    const site = await siteConfigurationLifecycle.create({
      organizationId: "org_1",
      domain: "example.com",
      name: "Example",
    });

    expect(state.insertedValues).toHaveLength(2);
    expect(state.insertedValues[0].id).not.toBe(state.insertedValues[1].id);
    expect(site.id).toBe(state.insertedValues[1].id);
  });

  it("reports a duplicate domain rather than retrying it", async () => {
    state.insertErrors = [{ code: "23505", constraint_name: "sites_domain_unique" }];

    await expect(
      siteConfigurationLifecycle.create({ organizationId: "org_1", domain: "example.com", name: "Example" })
    ).rejects.toMatchObject({ code: "domain_conflict", statusCode: 409 });

    expect(state.insertedValues).toHaveLength(1);
  });

  it("retries an unclaimed site's public id too", async () => {
    state.insertErrors = [{ code: "23505", constraint_name: "sites_id_unique" }];

    await siteConfigurationLifecycle.createUnclaimed({ domain: "example.com" });

    expect(state.insertedValues).toHaveLength(2);
    expect(state.insertedValues[0].id).not.toBe(state.insertedValues[1].id);
  });
});
