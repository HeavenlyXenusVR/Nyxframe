import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "frontend",
  base: "/static/react/",
  plugins: [react()],
  build: {
    outDir: "../static/react",
    emptyOutDir: true,
    sourcemap: true,
    target: "es2020",
    rollupOptions: {
      output: {
        // Framework code changes far less often than the app itself; its own
        // long-lived hashed chunk stays in the browser cache across deploys
        // instead of being re-downloaded inside every new app bundle.
        manualChunks(id) {
          if (!id.includes("node_modules")) return undefined;
          if (/[\\/]node_modules[\\/](react|react-dom|scheduler|react-router|react-router-dom|@remix-run)[\\/]/.test(id)) return "vendor-react";
          if (/[\\/]node_modules[\\/]lucide-react[\\/]/.test(id)) return "vendor-icons";
          return undefined;
        },
      },
    },
  },
  server: {
    proxy: {
      "/api": "http://127.0.0.1:8789",
    },
  },
});
