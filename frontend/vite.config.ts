import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// In development the Vite server proxies API and WebSocket traffic to the FastAPI backend,
// keeping everything same-origin exactly as it is in production.
const backend = process.env.BACKEND_URL ?? "http://127.0.0.1:8080";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      "/api": { target: backend },
      "/health": { target: backend },
      "/ws": { target: backend, ws: true },
    },
  },
  build: { outDir: "dist", sourcemap: false },
});
