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

/** AI features with rate limits; each must have a row in public.ai_limits. */
export type QuotaKind = "suggest" | "image" | "plan" | "tidy" | "import" | "videos";

/**
 * Records one OpenAI-backed call for this user, or returns a message
 * explaining why they're over a limit (see consume_ai_quota / ai_limits in SQL).
 * Call it after validating the request and before calling OpenAI.
 */
/**
 * Returned (as the error message) when the user hasn't turned on Lamar's AI
 * helpers. The app recognises it and offers to turn them on.
 */
export const AI_CONSENT_REQUIRED = "ai_consent_required";

export async function consumeQuota(userId: string, kind: QuotaKind): Promise<string | null> {
  // Consent first: no OpenAI call for anyone who hasn't agreed to it.
  // (Video search only asks YouTube for a meal name, not OpenAI.)
  if (kind !== "videos") {
    const { data: consented, error: consentErr } = await adminClient().rpc("ai_consent_granted", { p_user: userId });
    if (consentErr) throw consentErr;
    if (consented !== true) return AI_CONSENT_REQUIRED;
  }

  const { data, error } = await adminClient().rpc("consume_ai_quota", { p_user: userId, p_kind: kind });
  if (error) throw error;
  return data as string | null;
}
