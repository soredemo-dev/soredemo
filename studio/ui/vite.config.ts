import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// The Studio server serves flat files from its public root and rewrites
// requests under /assets/<file> to <publicRoot>/<file>. So we emit every built
// asset flat into studio/public and reference it with base '/assets/'. No inline
// scripts/styles are emitted (the server's CSP is script-src 'self'; style-src
// 'self'), and nothing is fetched from a remote origin.
export default defineConfig({
  root: __dirname,
  base: '/assets/',
  plugins: [react()],
  build: {
    outDir: '../public',
    emptyOutDir: true,
    assetsDir: '',
    target: 'es2022',
    modulePreload: { polyfill: false },
    assetsInlineLimit: 0,
    rollupOptions: {
      output: {
        entryFileNames: '[name]-[hash].js',
        chunkFileNames: '[name]-[hash].js',
        assetFileNames: '[name]-[hash][extname]',
      },
    },
  },
});
