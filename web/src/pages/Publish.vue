<script setup lang="ts">
import { onMounted, ref } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";
import { api } from "../api";
import { useConsole } from "../store";
import type { Build, Publisher, Token } from "../types";
const store = useConsole();
const state = ref<Publisher>();
const builds = ref<Build[]>([]);
const tokens = ref<Token[]>([]);
const tokenName = ref("");
const tokenUrl = ref("");
const urlDialog = ref(false);
async function load() {
  const [s, b, t] = await Promise.all([
    api<Publisher>("publisher/status"),
    api<Build[]>("builds"),
    api<Token[]>("publisher/tokens"),
  ]);
  state.value = s;
  builds.value = b.filter((x) => x.status === "success");
  tokens.value = t;
}
async function publish(build: Build) {
  const ok = await ElMessageBox.confirm(
    `发布构建 #${build.id}？所有已有订阅地址将更新为这份配置。`,
    "发布配置",
    { confirmButtonText: "发布", cancelButtonText: "取消" },
  ).catch(() => false);
  if (ok)
    await store.run("发布构建", async () => {
      await api("publisher/publish", "POST", { build_id: build.id });
      await load();
      ElMessage.success("已发布");
    });
}
async function rollback() {
  const ok = await ElMessageBox.confirm(
    "切换回上一版本？当前与上一版本将互换。",
    "回滚",
    { confirmButtonText: "回滚", cancelButtonText: "取消" },
  ).catch(() => false);
  if (ok)
    await store.run("回滚发布", async () => {
      await api("publisher/rollback", "POST");
      await load();
    });
}
async function createToken() {
  await store.run("创建设备订阅", async () => {
    const result = await api<{ url: string }>("publisher/tokens", "POST", {
      name: tokenName.value,
    });
    tokenUrl.value = result.url;
    urlDialog.value = true;
    tokenName.value = "";
    await load();
  });
}
async function copyUrl() {
  try {
    await navigator.clipboard.writeText(tokenUrl.value);
    ElMessage.success("已复制");
  } catch {
    ElMessage.info("请手动选中并复制地址");
  }
}
async function revoke(token: Token) {
  const ok = await ElMessageBox.confirm(
    `吊销“${token.name}”？该设备订阅地址将失效。`,
    "吊销订阅",
    { type: "warning", confirmButtonText: "吊销", cancelButtonText: "取消" },
  ).catch(() => false);
  if (ok)
    await store.run("吊销订阅", async () => {
      await api(`publisher/tokens/${encodeURIComponent(token.name)}`, "DELETE");
      await load();
    });
}
onMounted(() => store.read(load));
</script>

<template>
  <div class="split">
    <div class="panel">
      <div class="panel-heading">
        <h2>当前版本</h2>
        <el-tag size="small" :type="state?.current ? 'success' : 'info'">{{
          state?.current ? "已发布" : "未发布"
        }}</el-tag>
      </div>
      <div class="mono">
        {{ state?.current || "尚未发布，请选择下方成功构建。" }}
      </div>
    </div>
    <div class="panel">
      <div class="panel-heading">
        <h2>上一版本</h2>
        <el-button
          size="small"
          :disabled="!state?.previous || store.busy"
          @click="rollback"
          >回滚到此版本</el-button
        >
      </div>
      <div class="mono">{{ state?.previous || "暂无上一版本" }}</div>
    </div>
  </div>
  <div class="panel">
    <div class="panel-heading">
      <h2>可发布构建</h2>
      <el-button
        text
        :disabled="store.busy"
        @click="store.run('读取发布状态', load)"
        >刷新</el-button
      >
    </div>
    <el-table :data="builds"
      ><el-table-column prop="id" label="#" width="70" /><el-table-column
        prop="profile_name"
        label="配置"
      /><el-table-column
        prop="final_node_count"
        label="节点"
        width="90"
      /><el-table-column
        prop="created_at"
        label="构建时间"
        min-width="180"
      /><el-table-column label="操作" width="85"
        ><template #default="{ row }"
          ><el-button
            link
            type="primary"
            :disabled="store.busy"
            @click="publish(row)"
            >发布</el-button
          ></template
        ></el-table-column
      ></el-table
    >
    <p style="margin-top: 15px">
      所有配置共用一个 Publisher
      当前版本；选择不同配置发布会更新全部已有设备订阅。
    </p>
    <p>Publisher 历史版本：{{ state?.builds.join("、") || "暂无" }}</p>
  </div>
  <div class="panel">
    <div class="panel-heading"><h2>设备订阅</h2></div>
    <div class="toolbar">
      <el-input
        v-model="tokenName"
        maxlength="80"
        placeholder="设备名称，例如：手机"
      /><el-button
        type="primary"
        :disabled="!state?.current || !tokenName.trim() || store.busy"
        @click="createToken"
        >创建订阅地址</el-button
      ><span class="muted">完整地址仅在创建时显示一次</span>
    </div>
    <el-table :data="tokens"
      ><el-table-column prop="name" label="名称" /><el-table-column
        prop="fingerprint"
        label="指纹"
        min-width="180"
      /><el-table-column label="状态" width="95"
        ><template #default="{ row }"
          ><el-tag size="small" :type="row.active ? 'success' : 'info'">{{
            row.active ? "有效" : "已吊销"
          }}</el-tag></template
        ></el-table-column
      ><el-table-column
        prop="created_at"
        label="创建时间"
        min-width="180"
      /><el-table-column label="操作" width="75"
        ><template #default="{ row }"
          ><el-button
            link
            type="danger"
            :disabled="!row.active || store.busy"
            @click="revoke(row)"
            >吊销</el-button
          ></template
        ></el-table-column
      ></el-table
    >
  </div>
  <el-dialog
    v-model="urlDialog"
    title="设备订阅已创建"
    width="550px"
    @closed="tokenUrl = ''"
    ><p style="margin-bottom: 15px">
      请复制到设备客户端。关闭后不会再次显示完整地址。
    </p>
    <div class="token-url">{{ tokenUrl }}</div>
    <template #footer
      ><el-button @click="copyUrl">复制地址</el-button
      ><el-button type="primary" @click="urlDialog = false"
        >已保存</el-button
      ></template
    ></el-dialog
  >
</template>
