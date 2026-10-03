import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./api";

afterEach(() => vi.unstubAllGlobals());
describe("management API client", () => {
  it("sends the CSRF header and does not persist the subscription URL", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue({ ok: true, json: async () => ({ id: 1 }) });
    vi.stubGlobal("fetch", fetchMock);
    expect(
      await api("sources", "POST", {
        subscription_url: "https://example.invalid/fixture",
      }),
    ).toEqual({ id: 1 });
    expect(fetchMock.mock.calls[0][1]).toMatchObject({
      cache: "no-store",
      headers: { "X-MPK-Request": "1", "Content-Type": "application/json" },
    });
  });
  it("reports safe API failures", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        json: async () => ({
          error: { code: "invalid_selection", message: "Select a Profile." },
        }),
      }),
    );
    await expect(api("nodes")).rejects.toThrow("Select a Profile.");
  });
});
