import { defineApp } from 'convex/server';
import staticHosting from '@convex-dev/static-hosting/convex.config.js';

// The website (web/) is served from the deployment's own .convex.site URL,
// so a thread has a link: https://<deployment>.convex.site/t/<threadId>.
// Our own HTTP routes (none yet) would go under /api so the site owns the root.
const app = defineApp({ httpPrefix: '/api' });
app.use(staticHosting, { httpPrefix: '/' });
export default app;
