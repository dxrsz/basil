// Sends queued push notifications (see 20261005140100_push_notifications.sql).
//
// POST { type: "flush" } with header x-notify-secret: <private.notify_config.secret>
//   -> { ok, fcm, messages: [{ kind, list_id, title, body, recipients, results }] }
//
// Called by the database (pg_net, from triggers and a 30 s pg_cron job), never
// by the app, so verify_jwt is off and the caller proves itself with the shared
// secret instead. Claiming is atomic, so overlapping calls never double-send.
//
// Without the FCM_SERVICE_ACCOUNT secret (Firebase not set up yet) it still
// claims and composes everything, logs, and returns 200 without sending, so the
// queue can't back up.

import { adminClient } from "../_shared/clients.ts";
import { json } from "../_shared/cors.ts";
import { loadServiceAccount, send, type SendResult } from "./fcm.ts";

interface Event {
  kind: "shopping" | "items_added" | "member_joined";
  list_id: string;
  actor_id: string;
  item_count: number;
  names: string[];
}

function firstName(name: string | undefined): string {
  const n = (name ?? "").trim();
  return n ? n.split(/\s+/)[0] : "Someone";
}

function listing(names: string[]): string {
  if (names.length <= 1) return names[0] ?? "";
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

export function compose(e: Event, actor: string, list: { name: string; emoji: string }) {
  const who = firstName(actor);
  switch (e.kind) {
    case "shopping":
      return {
        title: `${who} is at the store 🛒`,
        body: `Anything to add to ${list.name}? Now's your chance (Lamar wants treats).`,
      };
    case "member_joined":
      return {
        title: `${who} joined ${list.name} ${list.emoji}`,
        body: "One more human to fetch things for Lamar. 🐾",
      };
    case "items_added": {
      const n = e.item_count;
      const named = e.names.length === n && n <= 3;
      return {
        title: `${list.emoji} ${list.name}`,
        body: named
          ? `${who} added ${listing(e.names)} to ${list.name}`
          : `${who} added ${n} things to ${list.name}`,
      };
    }
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const db = adminClient();
  const secret = req.headers.get("x-notify-secret") ?? "";
  const { data: ok, error: authErr } = await db.rpc("notify_secret_matches", { p_secret: secret });
  if (authErr) {
    console.error("notify: secret check failed:", authErr.message);
    return json({ error: "unavailable" }, 500);
  }
  if (!secret || ok !== true) return json({ error: "forbidden" }, 401);

  const { data: claimed, error: claimErr } = await db.rpc("claim_notifications");
  if (claimErr) {
    console.error("notify: claim failed:", claimErr.message);
    return json({ error: claimErr.message }, 500);
  }
  const events = (claimed ?? []) as Event[];
  const sa = loadServiceAccount();
  if (!sa && events.length) {
    console.log(`notify: FCM_SERVICE_ACCOUNT not set; dropping ${events.length} event(s) without sending`);
  }

  const listIds = [...new Set(events.map((e) => e.list_id))];
  const actorIds = [...new Set(events.map((e) => e.actor_id))];
  const [{ data: lists }, { data: profiles }] = await Promise.all([
    listIds.length ? db.from("lists").select("id, name, emoji").in("id", listIds) : { data: [] },
    actorIds.length ? db.from("profiles").select("id, display_name").in("id", actorIds) : { data: [] },
  ]);
  const listById = new Map((lists ?? []).map((l: any) => [l.id, l]));
  const nameById = new Map((profiles ?? []).map((p: any) => [p.id, p.display_name as string]));

  const messages = [];
  const dead = new Set<string>();
  for (const e of events) {
    const list = listById.get(e.list_id);
    if (!list) continue; // deleted since
    const { title, body } = compose(e, nameById.get(e.actor_id) ?? "", list);
    const { data: recipients, error: rErr } = await db.rpc("notification_recipients", {
      p_list_id: e.list_id,
      p_actor: e.actor_id,
      p_kind: e.kind,
    });
    if (rErr) {
      console.error("notify: recipients failed:", rErr.message);
      continue;
    }
    const tokens = [...new Set((recipients ?? []).map((r: { token: string }) => r.token))] as string[];
    const results: Record<string, number> = {};
    if (sa) {
      const outcomes: SendResult[] = await Promise.all(tokens.map((token) =>
        send(sa, {
          token,
          title,
          body,
          data: { kind: e.kind, list_id: e.list_id },
          collapseKey: `${e.kind}:${e.list_id}`,
        }).catch((err) => {
          console.error("notify: send error:", (err as Error).message);
          return "failed" as const;
        })
      ));
      outcomes.forEach((o, i) => {
        results[o] = (results[o] ?? 0) + 1;
        if (o === "unregistered") dead.add(tokens[i]);
      });
    }
    messages.push({ kind: e.kind, list_id: e.list_id, title, body, recipients: tokens.length, results });
  }

  if (dead.size) await db.from("device_tokens").delete().in("token", [...dead]);

  return json({ ok: true, fcm: sa ? "configured" : "not configured", messages });
});
