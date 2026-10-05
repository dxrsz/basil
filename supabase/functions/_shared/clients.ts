import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** A client that acts as the calling user, so RLS applies to every query. */
export function userClient(req: Request): SupabaseClient {
  return createClient(url, anonKey, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
}

/** Service-role client. Only use after authorising the caller via userClient. */
export function adminClient(): SupabaseClient {
  return createClient(url, serviceKey, { auth: { persistSession: false } });
}

/**
 * Records one OpenAI-backed call for this user, or returns a message
 * explaining why they're over their limit (see consume_ai_quota in SQL).
 */
export async function consumeQuota(userId: string, kind: "suggest" | "image"): Promise<string | null> {
  const { data, error } = await adminClient().rpc("consume_ai_quota", { p_user: userId, p_kind: kind });
  if (error) throw error;
  return data as string | null;
}
