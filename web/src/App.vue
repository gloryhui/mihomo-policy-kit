<script setup lang="ts">
import { useRoute } from "vue-router";
import { useConsole } from "./store";
const route = useRoute();
const store = useConsole();
const links = [
  ["/", "概览", "01"],
  ["/sources", "订阅源", "02"],
  ["/nodes", "节点池", "03"],
  ["/profiles", "构建配置", "04"],
  ["/publish", "发布", "05"],
];
</script>

<template>
  <div class="shell">
    <aside class="sidebar">
      <a class="brand" href="/admin/"
        ><span class="brand-mark">M</span
        ><span>MPK<small>订阅控制台</small></span></a
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
        <span class="dot"></span> Mihomo Policy Kit<small
          >v0.5 · 控制台 MVP</small
        >
      </div>
    </aside>
    <main>
      <header class="topbar">
        <span>工作空间 / {{ route.meta.title }}</span
        ><span class="badge">私有订阅管理</span>
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
