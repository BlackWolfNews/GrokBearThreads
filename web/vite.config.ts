import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The website (docs/website.md). Built into web/dist, which
// `npm run web:deploy` uploads to the Convex deployment's static hosting.
export default defineConfig({
  root: 'web',
  envDir: '..',
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true },
  server: { port: 5181 },
});
