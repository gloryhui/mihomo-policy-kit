import { createApp } from "vue";
import { createPinia } from "pinia";
import { createRouter, createWebHistory } from "vue-router";
import ElementPlus from "element-plus";
import "element-plus/dist/index.css";
import "./style.css";
import App from "./App.vue";
import Dashboard from "./pages/Dashboard.vue";
import Sources from "./pages/Sources.vue";
import Nodes from "./pages/Nodes.vue";
import Profiles from "./pages/Profiles.vue";
import Publish from "./pages/Publish.vue";

const router = createRouter({
  history: createWebHistory("/admin/"),
  routes: [
    {
      path: "/",
      component: Dashboard,
      meta: { title: "概览", subtitle: "所有订阅，一处管理。" },
    },
    {
      path: "/sources",
      component: Sources,
      meta: { title: "订阅源", subtitle: "添加订阅，设置节点命名与倍率上限。" },
    },
    {
      path: "/nodes",
      component: Nodes,
      meta: {
        title: "节点池",
        subtitle: "筛选节点，为每份配置决定保留或排除。",
      },
    },
    {
      path: "/profiles",
      component: Profiles,
      meta: {
        title: "构建配置",
        subtitle: "组合订阅源，选择分流方案，生成配置。",
      },
    },
    {
      path: "/publish",
      component: Publish,
      meta: {
        title: "发布",
        subtitle: "发布已验证的构建，为设备创建稳定订阅。",
      },
    },
  ],
});
createApp(App).use(createPinia()).use(router).use(ElementPlus).mount("#app");
