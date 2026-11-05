import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { ConvexProvider, ConvexReactClient } from 'convex/react';
import { App } from './App';
import { takeTokenFromHash } from './token';
import { applyTheme } from './theme';
import './styles.css';

// A sign-in link (`npm run web:sign-in`) carries the token in the fragment,
// which never reaches a server. Keep it and wipe it from the address bar
// before anything renders.
takeTokenFromHash();
applyTheme();

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL as string);

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ConvexProvider client={convex}>
      <App />
    </ConvexProvider>
  </StrictMode>,
);
