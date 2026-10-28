import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The website (docs/website.md). Built into web/dist, which
// `npm run web:deploy` uploads to the Convex deployment's static hosting.
export default defineConfig(({ command }) => {
  // The Convex URL is baked in at build time. static-hosting's deploy and
  // `upload --build` set it; a plain build without it would ship a site
  // that can't load anything.
  if (command === 'build' && !process.env.VITE_CONVEX_URL) throw new Error('VITE_CONVEX_URL is not set: use npm run web:deploy');
  return {
    root: 'web',
    envDir: '..',
    plugins: [react()],
    build: { outDir: 'dist', emptyOutDir: true },
    server: { port: 5181 },
  };
});
