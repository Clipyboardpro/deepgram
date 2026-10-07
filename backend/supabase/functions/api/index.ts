import { createApp } from "./app.ts";
import { repositoryFromEnvironment } from "./repository.ts";
import { createClient } from "@supabase/supabase-js";
import { SupabasePipeline } from "./pipeline-repository.ts";

// Supabase giriş yolu /functions/v1/api/v1/...; sözleşmedeki mantıksal kök /v1.
const secret = Deno.env.get("DISPATCHER_SECRET");
if (secret && secret.length < 32) {
  throw new Error("DISPATCHER_SECRET must have at least 32 characters");
}
const app = createApp(
  repositoryFromEnvironment(),
  secret
    ? {
      secret,
      publicUrl: Deno.env.get("PUBLIC_SUPABASE_URL")!,
      repo: new SupabasePipeline(
        createClient(
          Deno.env.get("SUPABASE_URL")!,
          Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
          {
            auth: { persistSession: false, autoRefreshToken: false },
            global: {
              fetch: (input, init) =>
                fetch(input, { ...init, signal: AbortSignal.timeout(15000) }),
            },
          },
        ),
      ),
    }
    : undefined,
);
Deno.serve((request) => {
  const url = new URL(request.url);
  if (url.pathname === "/api" || url.pathname.startsWith("/api/")) {
    url.pathname = url.pathname.slice(4) || "/";
  }
  return app.fetch(new Request(url, request));
});
