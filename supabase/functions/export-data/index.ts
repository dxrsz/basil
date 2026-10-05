// "Download my data": everything stored about the caller, as JSON
// (GDPR right of access / portability).
//
// POST {} -> { exported_at, account, profile, taste_profile, lists, ... }

import { error, json, preflight } from "../_shared/cors.ts";
import { adminClient, userClient } from "../_shared/clients.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return error("POST only", 405);
  const { data: auth } = await userClient(req).auth.getUser();
  if (!auth.user) return error("Not signed in", 401);
  const uid = auth.user.id;
  const db = adminClient();

  type Row = Record<string, unknown>;
  const rows = async (table: string, select: string, column: string, value: unknown): Promise<Row[]> => {
    const { data, error: e } = await db.from(table).select(select).eq(column, value);
    if (e) throw new Error(`${table}: ${e.message}`);
    return (data ?? []) as unknown as Row[];
  };

  try {
    const memberships = await rows("list_members", "list_id, role, joined_at", "user_id", uid);
    const listIds = memberships.map((m) => m.list_id as string);
    const { data: lists } = listIds.length
      ? await db.from("lists").select("id, name, emoji, owner_id, created_at").in("id", listIds)
      : { data: [] };
    const { data: user } = await db.auth.admin.getUserById(uid);

    return json({
      exported_at: new Date().toISOString(),
      account: {
        id: uid,
        email: user.user?.email ?? null,
        created_at: user.user?.created_at,
        sign_in_methods: (user.user?.identities ?? []).map((i) => i.provider),
      },
      profile: (await rows("profiles", "display_name, avatar_url, ai_consent, ai_consent_at, created_at", "id", uid))[0] ?? null,
      taste_profile: (await rows("taste_profiles", "*", "user_id", uid))[0] ?? null,
      lists: ((lists ?? []) as Row[]).map((l) => ({
        ...l,
        you_own_it: l.owner_id === uid,
        membership: memberships.find((m) => m.list_id === l.id),
      })),
      items_you_added: await rows("items", "list_id, name, quantity, category, checked, created_at", "created_by", uid),
      meals_you_created: await rows("recipes", "list_id, name, created_at", "created_by", uid),
      meal_history: await rows("meal_events", "list_id, meal_name, kind, rating, detail, created_at", "user_id", uid),
      notification_settings: (await rows("notification_settings", "*", "user_id", uid))[0] ?? null,
      muted_lists: await rows("list_mutes", "list_id", "user_id", uid),
      devices: (await rows("device_tokens", "platform, created_at, updated_at", "user_id", uid)),
      ai_usage_last_2_days: await rows("ai_usage", "kind, created_at", "user_id", uid),
    });
  } catch (e) {
    console.error("export-data:", e instanceof Error ? e.message : e);
    return error("Couldn't put your data together. Try again.", 500);
  }
});
