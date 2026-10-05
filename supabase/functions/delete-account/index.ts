// Deletes the caller's account and personal data.
//
// POST {} -> { ok: true, lists: { handed_over, deleted } }
//
// 1. Revoke Sign in with Apple, if they used it (Apple requires this).
// 2. Lists they own: shared ones pass to the member who joined earliest;
//    lists only they use are deleted with everything in them.
// 3. Delete the auth user. Personal data cascades away (profile, tastes,
//    devices, settings, usage); things they added to shared lists stay for
//    the rest of the household but are no longer linked to them.
// Meal photos of deleted lists are removed by the nightly housekeeping.

import { error, json, preflight } from "../_shared/cors.ts";
import { adminClient, userClient } from "../_shared/clients.ts";
import { revoke } from "../_shared/apple.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return error("POST only", 405);
  const { data: auth } = await userClient(req).auth.getUser();
  if (!auth.user) return error("Not signed in", 401);
  const uid = auth.user.id;
  const admin = adminClient();

  // 1. Apple. Best effort: a failure here shouldn't block deleting their data.
  const { data: apple } = await admin.rpc("apple_token_for", { p_user: uid });
  const token = (apple as { client_id: string; refresh_token: string }[] | null)?.[0];
  if (token) {
    try {
      await revoke(token.refresh_token, token.client_id);
    } catch (e) {
      console.error("delete-account: Apple revoke failed", e instanceof Error ? e.message : e);
    }
  }

  // 2. Lists.
  const { data: lists, error: listErr } = await admin.rpc("release_owned_lists", { p_user: uid });
  if (listErr) {
    console.error("delete-account: lists", listErr.message);
    return error("Couldn't delete the account. Nothing was changed; try again.", 500);
  }

  // 3. The account itself.
  const { error: delErr } = await admin.auth.admin.deleteUser(uid);
  if (delErr) {
    console.error("delete-account: deleteUser", delErr.message);
    return error("Couldn't finish deleting the account. Try again.", 500);
  }
  return json({ ok: true, lists });
});
