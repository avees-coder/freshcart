import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In development, Vite proxies /api to a locally running API.
// In containers, nginx does the same job (see nginx/default.conf.template),
// so the browser only ever talks to ONE origin and needs no API URL baked in.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": process.env.API_URL || "http://localhost:3000" },
  },
});
