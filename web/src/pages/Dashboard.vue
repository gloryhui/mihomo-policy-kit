<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api } from "../api";
import { useConsole } from "../store";
import type { Dashboard } from "../types";
const store = useConsole();
const data = ref<Dashboard>();
function load() {
  return store.read(async () => {
    data.value = await api<Dashboard>("dashboard");
  });
}
onMounted(load);
</script>

<template>
  <div class="steps">
    <b>01 添加订阅源</b><span>→</span><b>02 筛选节点</b><span>→</span
    ><b>03 构建配置</b><span>→</span><b>04 发布到设备</b>
  </div>
  <template v-if="data">
    <div class="stats">
      <div class="stat">
        <small>订阅源</small><strong>{{ data.source_count }}</strong
        ><RouterLink class="hint" to="/sources">管理订阅源 ↗</RouterLink>
      </div>
      <div class="stat">
        <small>节点库存</small><strong>{{ data.node_count }}</strong
        ><span class="hint">包含历史不可用节点</span>
      </div>
      <div class="stat">
        <small>可用节点</small><strong>{{ data.available_node_count }}</strong
        ><RouterLink class="hint" to="/nodes">筛选与选择 ↗</RouterLink>
      </div>
      <div class="stat">
        <small>构建配置</small><strong>{{ data.profile_count }}</strong
        ><RouterLink class="hint" to="/profiles">管理配置 ↗</RouterLink>
      </div>
    </div>
    <div class="split">
      <div class="panel">
        <div class="panel-heading">
          <h2>当前发布</h2>
          <el-tag
            size="small"
            :type="data.publisher.current ? 'success' : 'info'"
            >{{ data.publisher.current ? "已发布" : "尚未发布" }}</el-tag
          >
        </div>
        <div class="mono">
          {{ data.publisher.current || "完成构建后，在发布页发布第一份配置。" }}
        </div>
        <p style="margin-top: 16px">稳定订阅随发布更新，设备无需更换地址。</p>
        <el-button style="margin-top: 20px" @click="$router.push('/publish')"
          >前往发布</el-button
        >
      </div>
      <div class="panel">
        <div class="panel-heading">
          <h2>最近刷新</h2>
          <el-button text :disabled="store.busy" @click="load"
            >刷新概览</el-button
          >
        </div>
        <el-table :data="data.recent_sources"
          ><el-table-column prop="name" label="订阅源" /><el-table-column
            prop="available_node_count"
            label="可用"
            width="70" /><el-table-column
            prop="last_status"
            label="状态"
            width="90"
        /></el-table>
      </div>
    </div>
    <div class="panel">
      <div class="panel-heading">
        <h2>最近构建</h2>
        <RouterLink class="muted" to="/profiles">管理构建配置 ↗</RouterLink>
      </div>
      <el-table :data="data.recent_builds"
        ><el-table-column prop="id" label="#" width="65" /><el-table-column
          prop="profile_name"
          label="配置" /><el-table-column
          prop="status"
          label="状态"
          width="100" /><el-table-column
          prop="selected_node_count"
          label="入选节点"
          width="110" /><el-table-column
          prop="final_node_count"
          label="最终节点"
          width="110" /><el-table-column
          prop="created_at"
          label="构建时间"
          min-width="170"
      /></el-table>
    </div>
  </template>
  <el-empty v-else description="等待 API 数据；请确认后端已启动。"
    ><el-button @click="load">重试</el-button></el-empty
  >
</template>
