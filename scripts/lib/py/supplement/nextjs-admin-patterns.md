# Next.js Admin Dashboard Patterns

> Supplement document — livemask-admin Next.js patterns
> Source: Next.js docs + livemask-admin implementation

## Route Organization

```
app/
  (dashboard)/              # Route group — shared layout
    layout.tsx              # Sidebar + header layout
    page.tsx                # Default dashboard page
    nodes/
      page.tsx              # Node list
      [id]/
        page.tsx            # Node detail
    users/
      page.tsx              # User list
      [id]/
        page.tsx            # User detail
    settings/
      page.tsx              # System settings
  api/                      # API routes (proxy to backend)
    [...path]/
      route.ts              # Catch-all proxy
  auth/
    login/
      page.tsx              # Login page
    layout.tsx              # Auth layout (no sidebar)
```

## Backend Proxy Pattern

```typescript
// app/api/[...path]/route.ts
export async function GET(
  req: NextRequest,
  { params }: { params: { path: string[] } }
) {
  const backendUrl = process.env.NEXT_PUBLIC_API_BASE || 'http://backend:8080';
  const path = params.path.join('/');
  const url = new URL(path, backendUrl);
  url.search = req.nextUrl.search;

  const res = await fetch(url, {
    headers: {
      'Authorization': req.headers.get('Authorization') || '',
      'Content-Type': 'application/json',
    },
  });

  return new Response(res.body, {
    status: res.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
```

## State Management with Provider + Zustand

```typescript
// lib/stores/auth-store.ts
import { create } from 'zustand';

interface AuthState {
  token: string | null;
  user: User | null;
  login: (token: string) => void;
  logout: () => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  token: null,
  user: null,
  login: (token: string) => set({ token }),
  logout: () => set({ token: null, user: null }),
}));
```
