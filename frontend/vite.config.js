import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// /api is forwarded to the Spring Boot backend, so the browser never needs CORS.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { '/api': 'http://localhost:8080' } },
});
