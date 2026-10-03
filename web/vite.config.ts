import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig(({ mode }) => ({
  base: mode === "desktop" ? "./" : "/admin/",
  define: {
    "import.meta.env.VITE_MPK_DESKTOP": JSON.stringify(
      mode === "desktop" ? "1" : "0",
    ),
  },
  plugins: [vue()],
  server: {
    strictPort: true,
    port: 5173,
    proxy: { "/api": "http://127.0.0.1:9292" },
  },
}));
