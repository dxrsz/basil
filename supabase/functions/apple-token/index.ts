// Stores the caller's Apple refresh token so deleting their account can
// revoke Sign in with Apple. Called right after an Apple sign-in, with
// either the native sheet's authorization code (exchanged here) or, for the
// web flow, the provider refresh token Supabase handed the app.
//
// POST { authorization_code?: string, refresh_token?: string, client_id: string } -> { ok: true }

import { error, json, preflight } from "../_shared/cors.ts";
import { adminClient, userClient } from "../_shared/clients.ts";
import { refreshTokenFromCode } from "../_shared/apple.ts";

const CLIENT_IDS = new Set(["com.lamarsgroceries.app", "com.lamarsgroceries.signin"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return error("POST only", 405);
  const { data: auth } = await userClient(req).auth.getUser();
  if (!auth.user) return error("Not signed in", 401);

  const body = await req.json().catch(() => ({}));
  const clientId = String(body.client_id ?? "");
  if (!CLIENT_IDS.has(clientId)) return error("Unknown client_id");

  try {
    const token = typeof body.refresh_token === "string" && body.refresh_token
      ? body.refresh_token
      : typeof body.authorization_code === "string" && body.authorization_code
      ? await refreshTokenFromCode(body.authorization_code, clientId)
      : null;
    if (!token) return error("authorization_code or refresh_token is required");
    const { error: saveErr } = await adminClient().rpc("save_apple_token", {
      p_user: auth.user.id,
      p_client_id: clientId,
      p_refresh_token: token,
    });
    if (saveErr) throw saveErr;
    return json({ ok: true });
  } catch (e) {
    console.error("apple-token:", e instanceof Error ? e.message : e);
    return error("Couldn't save the Apple sign-in token", 502);
  }
});
