<script setup lang="ts">
import { onMounted, reactive, ref } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";
import { api } from "../api";
import { useConsole } from "../store";
import type { Build, Profile } from "../types";
const store = useConsole();
const dialog = ref(false);
const editing = ref<number>();
const builds = ref<Build[]>([]);
const form = reactive({
  name: "",
  enabled: true,
  provider: "smart-config-kit",
  dns_profile: "upstream",
  source_ids: [] as number[],
});
async function load() {
  await store.load();
  builds.value = await api<Build[]>("builds");
}
function open(profile?: Profile) {
  editing.value = profile?.id;
  Object.assign(form, {
    name: profile?.name || "",
    enabled: profile?.enabled ?? true,
    provider: profile?.provider || "smart-config-kit",
    dns_profile: profile?.dns_profile || "upstream",
    source_ids: [...(profile?.source_ids || [])],
  });
  dialog.value = true;
}
async function save() {
  await store.run("保存构建配置", async () => {
    await api(
      `profiles${editing.value ? `/${editing.value}` : ""}`,
      editing.value ? "PATCH" : "POST",
      form,
    );
    dialog.value = false;
    await load();
  });
}
async function build(profile: Profile) {
  await store.run("构建并校验", async () => {
    try {
      const result = await api<Build>(`profiles/${profile.id}/build`, "POST");
      ElMessage.success(
        `构建 #${result.id} 完成，${result.final_node_count} 个节点`,
      );
    } finally {
      await load();
    }
  });
}
async function remove(profile: Profile) {
  const ok = await ElMessageBox.confirm(
    `删除“${profile.name}”及其节点选择？历史构建保留。`,
    "删除构建配置",
    { type: "warning", confirmButtonText: "删除", cancelButtonText: "取消" },
  ).catch(() => false);
  if (ok)
    await store.run("删除配置", async () => {
      await api(`profiles/${profile.id}`, "DELETE");
      await load();
    });
}
onMounted(() => store.read(load));
</script>

<template>
  <div class="panel">
    <div class="panel-heading">
      <h2>构建配置</h2>
      <el-button type="primary" :disabled="store.busy" @click="open()"
        >+ 新建配置</el-button
      >
    </div>
    <el-table :data="store.profiles" empty-text="新建配置并关联订阅源。">
      <el-table-column
        prop="name"
        label="名称"
        min-width="160"
      /><el-table-column
        prop="provider"
        label="分流方案"
        min-width="160"
      /><el-table-column prop="dns_profile" label="DNS" width="135" />
      <el-table-column label="订阅源" min-width="150"
        ><template #default="{ row }">{{
          store.sources
            .filter((s) => row.source_ids.includes(s.id))
            .map((s) => s.name)
            .join("、") || "未关联"
        }}</template></el-table-column
      >
      <el-table-column label="状态" width="90"
        ><template #default="{ row }"
          ><el-tag size="small" :type="row.enabled ? 'success' : 'info'">{{
            row.enabled ? "启用" : "禁用"
          }}</el-tag></template
        ></el-table-column
      >
      <el-table-column label="操作" width="180"
        ><template #default="{ row }"
          ><el-button
            link
            type="primary"
            :disabled="store.busy || !row.enabled"
            @click="build(row)"
            >构建</el-button
          ><el-button link :disabled="store.busy" @click="open(row)"
            >编辑</el-button
          ><el-button
            link
            type="danger"
            :disabled="store.busy"
            @click="remove(row)"
            >删除</el-button
          ></template
        ></el-table-column
      >
    </el-table>
    <p style="margin-top: 18px">
      先刷新订阅源，再构建。仅生成 Mihomo 配置；构建成功后前往发布页。
    </p>
  </div>
  <div class="panel">
    <div class="panel-heading">
      <h2>构建记录</h2>
      <el-button
        text
        :disabled="store.busy"
        @click="store.run('读取构建记录', load)"
        >刷新</el-button
      >
    </div>
    <el-table :data="builds"
      ><el-table-column prop="id" label="#" width="65" /><el-table-column
        prop="profile_name"
        label="配置" /><el-table-column
        prop="status"
        label="状态"
        width="90" /><el-table-column label="原始 / 入选 / 最终" width="150"
        ><template #default="{ row }"
          >{{ row.original_node_count }} / {{ row.selected_node_count }} /
          {{ row.final_node_count }}</template
        ></el-table-column
      ><el-table-column
        prop="created_at"
        label="时间"
        min-width="180" /><el-table-column
        prop="error_safe"
        label="错误摘要"
        min-width="230"
    /></el-table>
  </div>
  <el-dialog
    v-model="dialog"
    :title="editing ? '编辑构建配置' : '新建构建配置'"
    width="520px"
  >
    <el-form label-position="top"
      ><el-form-item label="名称"
        ><el-input
          v-model="form.name"
          placeholder="例如：家庭主订阅"
          maxlength="120" /></el-form-item
      ><el-form-item label="关联订阅源"
        ><el-select v-model="form.source_ids" multiple style="width: 100%"
          ><el-option
            v-for="source in store.sources"
            :key="source.id"
            :label="source.name"
            :value="source.id" /></el-select></el-form-item
      ><el-form-item label="分流方案"
        ><el-select v-model="form.provider"
          ><el-option
            label="Smart-Config-Kit Normal"
            value="smart-config-kit" /><el-option
            label="ACL4SSR"
            value="acl4ssr" /></el-select></el-form-item
      ><el-form-item label="DNS 模式"
        ><el-select v-model="form.dns_profile"
          ><el-option label="保留上游（默认）" value="upstream" /><el-option
            label="国内兼容（Nikki 等场景）"
            value="china_compat" /></el-select></el-form-item
      ><el-form-item label="启用"
        ><el-switch v-model="form.enabled" /></el-form-item
    ></el-form>
    <template #footer
      ><el-button @click="dialog = false" :disabled="store.busy">取消</el-button
      ><el-button type="primary" :loading="store.busy" @click="save"
        >保存</el-button
      ></template
    >
  </el-dialog>
</template>
