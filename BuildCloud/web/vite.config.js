import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { viteSingleFile } from 'vite-plugin-singlefile'

// Un solo index.html con el JS y el CSS dentro: BuildCloud lo sirve desde memoria (WebApp.swift).
// En desarrollo (`npm run dev`) la API se pide a la app que ya está corriendo.
export default defineConfig({
  plugins: [svelte(), viteSingleFile()],
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8686',
      '/manifest': 'http://127.0.0.1:8686',
      '/files': 'http://127.0.0.1:8686',
    },
  },
})
