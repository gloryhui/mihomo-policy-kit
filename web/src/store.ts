import { defineStore } from "pinia";
import { ref } from "vue";
import { ElMessage } from "element-plus";
import { api } from "./api";
import type { Source, Profile } from "./types";

export const useConsole = defineStore("console", () => {
  const sources = ref<Source[]>([]);
  const profiles = ref<Profile[]>([]);
  const busy = ref(false);
  const task = ref("");
  async function load() {
    const [s, p] = await Promise.all([
      api<Source[]>("sources"),
      api<Profile[]>("profiles"),
    ]);
    sources.value = s;
    profiles.value = p;
  }
  async function run<T>(
    label: string,
    action: () => Promise<T>,
  ): Promise<T | undefined> {
    if (busy.value) return;
    busy.value = true;
    task.value = label;
    try {
      return await action();
    } catch (error) {
      ElMessage.error(error instanceof Error ? error.message : "操作失败");
    } finally {
      busy.value = false;
      task.value = "";
    }
  }
  async function read<T>(action: () => Promise<T>): Promise<T | undefined> {
    try {
      return await action();
    } catch (error) {
      ElMessage.error(error instanceof Error ? error.message : "读取失败");
    }
  }
  return { sources, profiles, busy, task, load, run, read };
});
