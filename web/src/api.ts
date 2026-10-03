import { invoke } from "@tauri-apps/api/core";
import { isDesktop, connectionEpoch } from "./desktop";

export async function api<T>(
  path: string,
  method = "GET",
  body?: unknown,
): Promise<T> {
  if (isDesktop()) {
    const epoch = connectionEpoch();
    try {
      const result = await invoke<T>("api_request", {
        path,
        method,
        body: body ?? null,
      });
      if (connectionEpoch() !== epoch) throw "连接已改变，请重新操作";
      return result;
    } catch (error) {
      throw new Error(typeof error === "string" ? error : "管理请求失败");
    }
  }
  const response = await fetch(`/api/v1/${path}`, {
    method,
    headers: {
      "X-MPK-Request": "1",
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
    credentials: "same-origin",
  });
  const data = await response.json().catch(() => null);
  if (!response.ok)
    throw new Error(data?.error?.message || `请求失败 (${response.status})`);
  return data as T;
}
