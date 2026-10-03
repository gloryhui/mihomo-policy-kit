import { ref } from "vue";
import { invoke } from "@tauri-apps/api/core";

export const connected = ref(false);
export const serverLabel = ref("");
export const isDesktop = () => import.meta.env.VITE_MPK_DESKTOP === "1";
const preferenceKey = "mpk.desktop.server.v1";

export function loadServer(): { endpoint: string; username: string } {
  try {
    const data = JSON.parse(localStorage.getItem(preferenceKey) || "{}");
    return {
      endpoint: typeof data.endpoint === "string" ? data.endpoint : "",
      username: typeof data.username === "string" ? data.username : "",
    };
  } catch {
    return { endpoint: "", username: "" };
  }
}

export async function connectServer(
  endpoint: string,
  username: string,
  password: string,
  certificatePem: string,
) {
  const origin = await invoke<string>("connect_server", {
    endpoint,
    username,
    password,
    certificatePem,
  });
  try {
    localStorage.setItem(
      preferenceKey,
      JSON.stringify({ endpoint: origin, username }),
    );
  } catch {
    /* Connection does not require persistent preferences. */
  }
  serverLabel.value = origin;
  connected.value = true;
}

export async function disconnectServer() {
  await invoke("disconnect_server");
  connected.value = false;
  serverLabel.value = "";
}
