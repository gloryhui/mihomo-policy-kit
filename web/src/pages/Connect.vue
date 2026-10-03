<script setup lang="ts">
import { ref } from "vue";
import { connectServer, loadServer } from "../desktop";
const saved = loadServer();
const endpoint = ref(saved.endpoint);
const username = ref(saved.username);
const password = ref("");
const certificatePem = ref("");
const certificateName = ref("");
const busy = ref(false);
const error = ref("");
async function certificate(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  certificatePem.value = "";
  certificateName.value = "";
  if (!file) return;
  if (file.size > 131072) {
    error.value = "证书文件不能超过 128 KB";
    input.value = "";
    return;
  }
  const pem = await file.text();
  if (
    !pem.includes("-----BEGIN CERTIFICATE-----") ||
    pem.includes("PRIVATE KEY")
  ) {
    error.value = "请选择 PEM 格式的公开证书（.crt 或 .pem），不要选择私钥";
    input.value = "";
    return;
  }
  certificatePem.value = pem;
  certificateName.value = file.name;
  error.value = "";
}
async function connect() {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await connectServer(
      endpoint.value,
      username.value,
      password.value,
      certificatePem.value,
    );
    certificatePem.value = "";
  } catch (cause) {
    error.value =
      typeof cause === "string"
        ? cause
        : "连接失败，请检查服务器地址与认证信息";
  } finally {
    password.value = "";
    busy.value = false;
  }
}
</script>

<template>
  <main class="connect-screen">
    <form class="connect-card" @submit.prevent="connect">
      <div class="brand-mark">M</div>
      <h1>连接你的控制台</h1>
      <p>集中管理订阅、节点、构建和发布。</p>
      <label
        >服务器地址<input
          v-model="endpoint"
          type="url"
          placeholder="https://example.com:8215"
          required
          :disabled="busy"
      /></label>
      <label
        >用户名<input
          v-model="username"
          autocomplete="username"
          required
          :disabled="busy"
      /></label>
      <label
        >密码<input
          v-model="password"
          type="password"
          autocomplete="off"
          required
          :disabled="busy"
      /></label>
      <details>
        <summary>自签名证书或私有 CA</summary>
        <p>
          从可信渠道获取服务器公开证书并导入。连接仍会验证证书和服务器地址。
        </p>
        <input
          type="file"
          accept=".crt,.pem"
          aria-label="导入服务器公开证书"
          :disabled="busy"
          @change="certificate"
        />
        <small v-if="certificateName">{{ certificateName }}</small>
      </details>
      <p v-if="error" class="connect-error" role="alert">{{ error }}</p>
      <button class="connect-button" type="submit" :disabled="busy">
        {{ busy ? "正在连接…" : "连接" }}
      </button>
      <small
        >地址和用户名会记住；密码和导入证书仅用于本次连接，退出后需重新输入。</small
      >
    </form>
  </main>
</template>
