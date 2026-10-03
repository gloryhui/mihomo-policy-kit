<script setup lang="ts">
import { onMounted, reactive, ref } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";
import { api } from "../api";
import { useConsole } from "../store";
import type { Source } from "../types";
const store = useConsole();
const dialog = ref(false);
const editing = ref<number>();
const form = reactive({
  name: "",
  enabled: true,
  input_kind: "remote",
  subscription_url: "",
  content: "",
  name_prefix: "",
  max_multiplier: undefined as number | undefined,
  unknown_multiplier_action: "allow",
  refresh_interval: 3600,
});
function open(source?: Source) {
  editing.value = source?.id;
  Object.assign(form, {
    name: source?.name || "",
    enabled: source?.enabled ?? true,
    input_kind: source?.input_kind || "remote",
    subscription_url: "",
    content: "",
    name_prefix: source?.name_prefix || "",
    max_multiplier: source?.max_multiplier ?? undefined,
    unknown_multiplier_action: source?.unknown_multiplier_action || "allow",
    refresh_interval: source?.refresh_interval || 3600,
  });
  dialog.value = true;
}
function clearSecrets() {
  form.subscription_url = "";
  form.content = "";
}
async function fileChanged(event: Event) {
  const file = (event.target as HTMLInputElement).files?.[0];
  if (!file) return;
  if (file.size > 10 * 1024 * 1024) {
    ElMessage.error("文件不能超过 10 MB");
    return;
  }
  form.content = await file.text();
}
async function save() {
  await store.run("保存订阅源", async () => {
    const payload: Record<string, unknown> = {
      ...form,
      max_multiplier: form.max_multiplier ?? null,
    };
    if (!form.subscription_url) delete payload.subscription_url;
    if (!form.content) delete payload.content;
    await api(
      `sources${editing.value ? `/${editing.value}` : ""}`,
      editing.value ? "PATCH" : "POST",
      payload,
    );
    clearSecrets();
    dialog.value = false;
    await store.load();
    ElMessage.success("已保存，刷新订阅源即可获取节点");
  });
}
async function refresh(source: Source) {
  await store.run("刷新订阅源", async () => {
    await api(`sources/${source.id}/refresh`, "POST");
    await store.load();
    ElMessage.success("节点库存已更新");
  });
}
async function toggle(source: Source) {
  await store.run("更新状态", async () => {
    await api(`sources/${source.id}`, "PATCH", { enabled: !source.enabled });
    await store.load();
  });
}
async function remove(source: Source) {
  const confirmed = await ElMessageBox.confirm(
    `删除“${source.name}”及其节点和选择记录？`,
    "删除订阅源",
    { type: "warning", confirmButtonText: "删除", cancelButtonText: "取消" },
  ).catch(() => false);
  if (!confirmed) return;
  await store.run("删除订阅源", async () => {
    await api(`sources/${source.id}`, "DELETE");
    await store.load();
  });
}
onMounted(() => store.read(store.load));
</script>

<template>
  <div class="panel">
    <div class="panel-heading">
      <h2>
        订阅源 <span class="muted">{{ store.sources.length }} 个</span>
      </h2>
      <el-button type="primary" :disabled="store.busy" @click="open()"
        >+ 添加订阅源</el-button
      >
    </div>
    <el-table
      :data="store.sources"
      empty-text="添加第一个订阅源，然后刷新获取节点。"
    >
      <el-table-column label="名称" min-width="150"
        ><template #default="{ row }"
          ><strong>{{ row.name }}</strong>
          <div class="muted">
            {{ row.secret_configured ? "已配置" : "未配置" }} ·
            {{ row.input_kind === "remote" ? "远程订阅" : "本地导入" }}
          </div></template
        ></el-table-column
      >
      <el-table-column prop="name_prefix" label="节点前缀" min-width="120" />
      <el-table-column label="倍率上限" width="100"
        ><template #default="{ row }">{{
          row.max_multiplier == null ? "不限" : `${row.max_multiplier}×`
        }}</template></el-table-column
      >
      <el-table-column label="可用 / 库存" width="105"
        ><template #default="{ row }"
          >{{ row.available_node_count }} / {{ row.node_count }}</template
        ></el-table-column
      >
      <el-table-column label="启用" width="75"
        ><template #default="{ row }"
          ><el-switch
            :model-value="row.enabled"
            :disabled="store.busy"
            @change="toggle(row)" /></template
      ></el-table-column>
      <el-table-column label="刷新状态" min-width="150"
        ><template #default="{ row }"
          ><el-tag
            size="small"
            :type="
              row.last_status === 'failed'
                ? 'danger'
                : row.last_status === 'success'
                  ? 'success'
                  : 'info'
            "
            >{{ row.last_status }}</el-tag
          >
          <div v-if="row.last_error_safe" class="muted">
            {{ row.last_error_safe }}
          </div>
          <div v-else class="muted">
            {{ row.last_refresh_at || "尚未刷新" }}
          </div></template
        ></el-table-column
      >
      <el-table-column label="操作" width="175" fixed="right"
        ><template #default="{ row }"
          ><el-button
            link
            type="primary"
            :disabled="store.busy"
            @click="refresh(row)"
            >刷新</el-button
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
  </div>
  <el-dialog
    v-model="dialog"
    :title="editing ? '编辑订阅源' : '添加订阅源'"
    width="560px"
    @closed="clearSecrets"
  >
    <el-form label-position="top" @submit.prevent="save">
      <el-form-item label="名称"
        ><el-input
          v-model="form.name"
          maxlength="120"
          placeholder="例如：主订阅"
      /></el-form-item>
      <el-form-item label="输入方式"
        ><el-radio-group v-model="form.input_kind"
          ><el-radio-button value="remote">远程 HTTPS 订阅</el-radio-button
          ><el-radio-button value="inline"
            >本地文件导入</el-radio-button
          ></el-radio-group
        ></el-form-item
      >
      <el-form-item
        v-if="form.input_kind === 'remote'"
        :label="editing ? '新订阅地址（留空保留已有地址）' : '订阅地址'"
        ><el-input
          v-model="form.subscription_url"
          type="password"
          autocomplete="off"
          placeholder="https://…"
        />
        <div class="field-hint">
          加密保存，列表不会回显完整地址。
        </div></el-form-item
      >
      <el-form-item v-else label="Mihomo YAML / base64 URI 列表"
        ><input type="file" accept=".yaml,.yml,.txt" @change="fileChanged" />
        <div class="field-hint">
          {{
            form.content
              ? "文件已读取，保存后可刷新。"
              : editing
                ? "留空保留原文件；替换时重新选择。"
                : "选择文件，最多 10 MB。"
          }}
        </div></el-form-item
      >
      <el-form-item label="节点名称前缀"
        ><el-input v-model="form.name_prefix" placeholder="例如：主订阅 | " />
        <div class="field-hint">
          多个订阅源使用不同前缀，避免节点重名。
        </div></el-form-item
      >
      <el-form-item label="最高倍率（清空表示不限）"
        ><el-input-number
          v-model="form.max_multiplier"
          :min="0.01"
          :precision="2"
        /><el-button text @click="form.max_multiplier = undefined"
          >不限</el-button
        ></el-form-item
      >
      <el-form-item label="未识别倍率的节点"
        ><el-radio-group v-model="form.unknown_multiplier_action"
          ><el-radio value="allow">保留</el-radio
          ><el-radio value="remove">排除</el-radio></el-radio-group
        ></el-form-item
      >
    </el-form>
    <template #footer
      ><el-button :disabled="store.busy" @click="dialog = false">取消</el-button
      ><el-button type="primary" :loading="store.busy" @click="save"
        >保存</el-button
      ></template
    >
  </el-dialog>
</template>
