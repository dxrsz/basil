// Deletes meal photos queued by public.housekeeping() (nightly, pg_cron):
// files no meal points to any more. Storage files have to be removed through
// the storage API; the database only knows which ones.
//
// Called by the database with x-housekeeping-secret, never by the app.

import { json } from "../_shared/cors.ts";
import { adminClient } from "../_shared/clients.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const db = adminClient();
  const secret = req.headers.get("x-housekeeping-secret") ?? "";
  const { data: ok } = await db.rpc("housekeeping_secret_matches", { p_secret: secret });
  if (!secret || ok !== true) return json({ error: "forbidden" }, 401);

  let removed = 0;
  for (let i = 0; i < 10; i++) {
    const { data: paths, error } = await db.rpc("claim_image_deletions", { p_limit: 500 });
    if (error) {
      console.error("housekeeping: claim failed", error.message);
      break;
    }
    const batch = (paths ?? []) as string[];
    if (batch.length === 0) break;
    const { data, error: rmErr } = await db.storage.from("recipe-images").remove(batch);
    if (rmErr) {
      console.error("housekeeping: remove failed", rmErr.message);
      break; // tomorrow's run re-queues anything still orphaned
    }
    removed += data?.length ?? 0;
  }
  return json({ removed });
});
