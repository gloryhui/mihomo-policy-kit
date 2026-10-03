import { afterEach, describe, expect, it, vi } from "vitest";
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
import { invoke } from "@tauri-apps/api/core";
import { api } from "./api";
import {
  connectServer,
  connected,
  disconnectServer,
  loadServer,
} from "./desktop";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  vi.mocked(invoke).mockReset();
  connected.value = false;
});

describe("desktop connections", () => {
  it("discards a native response delivered after disconnect", async () => {
    vi.stubEnv("VITE_MPK_DESKTOP", "1");
    let complete!: (value: unknown) => void;
    vi.mocked(invoke).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          complete = resolve;
        }),
    );
    const pending = api("sources");
    vi.mocked(invoke).mockResolvedValueOnce(undefined);
    await disconnectServer();
    complete([{ id: 99 }]);
    await expect(pending).rejects.toThrow("连接已改变");
  });
  it("routes desktop requests through the native authenticated channel", async () => {
    vi.stubEnv("VITE_MPK_DESKTOP", "1");
    vi.mocked(invoke).mockResolvedValue({ id: 7 });
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    expect(await api("profiles/7/build", "POST")).toEqual({ id: 7 });
    expect(invoke).toHaveBeenCalledWith("api_request", {
      path: "profiles/7/build",
      method: "POST",
      body: null,
    });
    expect(fetch).not.toHaveBeenCalled();
  });
  it("remembers only a validated address and username, never the password or certificate", async () => {
    const setItem = vi.fn();
    vi.stubGlobal("localStorage", { setItem, getItem: () => null });
    vi.mocked(invoke).mockResolvedValue("https://example.invalid");
    await connectServer(
      "https://example.invalid/",
      "fixture",
      "FAKE_PASSWORD",
      "FAKE_CA",
    );
    expect(connected.value).toBe(true);
    expect(setItem.mock.calls[0][1]).toBe(
      JSON.stringify({
        endpoint: "https://example.invalid",
        username: "fixture",
      }),
    );
    await disconnectServer();
    expect(connected.value).toBe(false);
    expect(invoke).toHaveBeenLastCalledWith("disconnect_server");
  });
  it("failed login does not persist a connection and damaged preferences recover", async () => {
    const setItem = vi.fn();
    vi.stubGlobal("localStorage", { setItem, getItem: () => "invalid json" });
    expect(loadServer()).toEqual({ endpoint: "", username: "" });
    vi.mocked(invoke).mockRejectedValue("认证失败");
    await expect(
      connectServer("https://example.invalid", "fixture", "fake", ""),
    ).rejects.toBe("认证失败");
    expect(setItem).not.toHaveBeenCalled();
    expect(connected.value).toBe(false);
  });
});
