import { createApp } from "./app.ts";
import { repositoryFromEnvironment } from "./repository.ts";

// Supabase giriş yolu /functions/v1/api/v1/...; sözleşmedeki mantıksal kök /v1.
const app = createApp(repositoryFromEnvironment());
Deno.serve((request) => {
  const url = new URL(request.url);
  if (url.pathname === "/api" || url.pathname.startsWith("/api/")) {
    url.pathname = url.pathname.slice(4) || "/";
  }
  return app.fetch(new Request(url, request));
});
