<script setup lang="ts">
import { useRoute } from "vue-router";
import { useConsole } from "./store";
import { connected, serverLabel, isDesktop, disconnectServer } from "./desktop";
import Connect from "./pages/Connect.vue";
const route = useRoute();
const store = useConsole();
async function disconnect() {
  await store.run("断开连接", async () => {
    await disconnectServer();
    store.sources = [];
    store.profiles = [];
  });
}
const links = [
  ["/", "概览", "01"],
  ["/sources", "订阅源", "02"],
  ["/nodes", "节点池", "03"],
  ["/profiles", "构建配置", "04"],
  ["/publish", "发布", "05"],
];
</script>

<template>
  <Connect v-if="isDesktop() && !connected" />
  <div v-else class="shell">
    <aside class="sidebar">
      <RouterLink class="brand" to="/"
        ><span class="brand-mark">M</span
        ><span>MPK<small>订阅控制台</small></span></RouterLink
      >
      <div class="nav-label">工作空间</div>
      <nav>
        <RouterLink
          v-for="[path, title, number] in links"
          :key="path"
          :to="path"
          ><span>{{ number }}</span
          >{{ title }}</RouterLink
        >
      </nav>
      <div class="sidebar-footer">
        <span class="dot"></span> Mihomo Policy Kit<small>{{
          isDesktop() ? "v0.6 · 桌面客户端" : "v0.5 · 控制台 MVP"
        }}</small>
      </div>
    </aside>
    <main>
      <header class="topbar">
        <span>工作空间 / {{ route.meta.title }}</span
        ><span class="badge">私有订阅管理</span>
        <div v-if="isDesktop()" class="server-toolbar">
          <span>{{ serverLabel }}</span>
          <button :disabled="store.busy" @click="disconnect">断开连接</button>
        </div>
      </header>
      <section class="content">
        <div class="page-heading">
          <div>
            <h1>{{ route.meta.title }}</h1>
            <p>{{ route.meta.subtitle }}</p>
          </div>
          <span v-if="store.busy" class="working">{{ store.task }}…</span>
        </div>
        <RouterView />
      </section>
    </main>
  </div>
</template>
