<script setup lang="ts">
import { onMounted, ref, reactive, watch } from "vue";
import { ElMessage } from "element-plus";
import { api } from "../api";
import { useConsole } from "../store";
import type { Node, Selection } from "../types";
const store = useConsole();
const filters = reactive({
  q: "",
  source_id: "",
  region: "",
  available: "",
  max_multiplier: "",
  unknown_multiplier: "",
  page: 1,
  per_page: 50,
});
const profileId = ref<number>();
const items = ref<Node[]>([]);
const total = ref(0);
const picked = ref<Node[]>([]);
async function load() {
  const query = new URLSearchParams(
    Object.entries(filters)
      .filter(([, value]) => value !== "")
      .map(([key, value]) => [key, String(value)]),
  );
  if (profileId.value) query.set("profile_id", String(profileId.value));
  const result = await api<{ items: Node[]; total: number }>(`nodes?${query}`);
  items.value = result.items;
  total.value = result.total;
  picked.value = [];
}
function search() {
  filters.page = 1;
  return store.run("筛选节点", load);
}
async function select(selection: Selection, ids: number[]) {
  if (!profileId.value || !ids.length) return;
  await store.run("更新节点选择", async () => {
    await api("nodes/batch-selection", "POST", {
      profile_id: profileId.value,
      node_ids: ids,
      selection,
    });
    await load();
    ElMessage.success("选择已保存");
  });
}
function pageChanged() {
  store.run("读取节点", load);
}
watch(profileId, search);
onMounted(() =>
  store.read(async () => {
    await store.load();
    await load();
  }),
);
</script>

<template>
  <div class="panel">
    <div class="panel-heading">
      <h2>节点库存</h2>
      <el-select
        v-model="profileId"
        placeholder="选择要编辑的构建配置"
        clearable
        :disabled="store.busy"
        style="width: 245px"
        ><el-option
          v-for="profile in store.profiles"
          :key="profile.id"
          :label="profile.name"
          :value="profile.id"
      /></el-select>
    </div>
    <el-alert
      v-if="!profileId"
      title="查看全部节点。选择构建配置后，可设置该配置的保留 / 排除规则。"
      type="info"
      :closable="false"
    />
    <div class="toolbar">
      <el-input
        v-model="filters.q"
        placeholder="搜索节点名称"
        clearable
        @keyup.enter="search"
      />
      <el-select v-model="filters.source_id" placeholder="所有订阅源" clearable
        ><el-option
          v-for="source in store.sources"
          :key="source.id"
          :label="source.name"
          :value="String(source.id)"
      /></el-select>
      <el-select v-model="filters.region" placeholder="所有地区" clearable
        ><el-option
          v-for="[value, label] in [
            ['hk', '香港'],
            ['jp', '日本'],
            ['us', '美国'],
            ['sg', '新加坡'],
            ['tw', '台湾'],
            ['mo', '澳门'],
            ['ch', '瑞士'],
            ['unknown', '未识别'],
          ]"
          :key="value"
          :label="label"
          :value="value"
      /></el-select>
      <el-select v-model="filters.available" placeholder="所有状态" clearable
        ><el-option label="可用" value="true" /><el-option
          label="不可用"
          value="false"
      /></el-select>
      <el-input
        v-model="filters.max_multiplier"
        placeholder="最大倍率"
        style="width: 115px"
      /><el-checkbox
        v-model="filters.unknown_multiplier"
        true-value="true"
        false-value=""
        >仅未知倍率</el-checkbox
      >
      <el-button :disabled="store.busy" @click="search">筛选</el-button>
    </div>
    <div class="toolbar">
      <span class="muted">已勾选 {{ picked.length }} 个 · 仅操作当前页</span
      ><span class="grow"></span
      ><el-button
        v-for="[value, label] in [
          ['auto', '恢复自动'],
          ['include', '强制保留'],
          ['exclude', '排除'],
        ]"
        :key="value"
        :disabled="!profileId || !picked.length || store.busy"
        @click="
          select(
            value as Selection,
            picked.map((n) => n.id),
          )
        "
        >{{ label }}</el-button
      >
    </div>
    <el-table
      :data="items"
      row-key="id"
      @selection-change="(rows: Node[]) => (picked = rows)"
    >
      <el-table-column type="selection" width="45" />
      <el-table-column label="节点" min-width="230"
        ><template #default="{ row }"
          ><strong>{{ row.display_name }}</strong>
          <div class="muted">{{ row.original_name }}</div></template
        ></el-table-column
      >
      <el-table-column
        prop="source_name"
        label="订阅源"
        width="110"
      /><el-table-column prop="region" label="地区" width="75" />
      <el-table-column label="倍率" width="75"
        ><template #default="{ row }"
          ><span class="cost">{{
            row.multiplier == null ? "未知" : `${row.multiplier}×`
          }}</span></template
        ></el-table-column
      >
      <el-table-column prop="protocol" label="协议" width="85" />
      <el-table-column label="状态" width="105"
        ><template #default="{ row }"
          ><el-tag size="small" :type="row.available ? 'success' : 'info'">{{
            row.available ? "可用" : "未再出现"
          }}</el-tag></template
        ></el-table-column
      >
      <el-table-column v-if="profileId" label="选择" width="135"
        ><template #default="{ row }"
          ><el-select
            :model-value="row.selection"
            size="small"
            :disabled="store.busy"
            @change="(value: Selection) => select(value, [row.id])"
            ><el-option label="自动" value="auto" /><el-option
              label="强制保留"
              value="include" /><el-option
              label="排除"
              value="exclude" /></el-select></template
      ></el-table-column>
      <el-table-column v-if="profileId" label="入选" width="65"
        ><template #default="{ row }">{{
          row.selected ? "是" : "否"
        }}</template></el-table-column
      >
    </el-table>
    <el-pagination
      v-model:current-page="filters.page"
      :page-size="filters.per_page"
      :total="total"
      layout="total, prev, pager, next"
      :disabled="store.busy"
      @current-change="pageChanged"
    />
    <p style="margin-top: 15px">
      自动遵循订阅源启用状态和倍率规则。强制保留可越过倍率限制；不可用节点始终不入选。
    </p>
  </div>
</template>
