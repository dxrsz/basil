// "Watch how to make it": YouTube videos for a meal.
//
// POST { recipe_id, refresh?: boolean }
//   -> { videos: [Video], cached: boolean }      (see youtube.ts for Video)
//
// Reads the meal through the caller's JWT (RLS: list members only), returns
// the cached videos when the meal hasn't been renamed, otherwise searches the
// YouTube Data API (YOUTUBE_API_KEY secret) and caches the result. A search
// costs 100 of YouTube's 10,000 free daily quota units, so lookups go through
// consumeQuota("videos"), whose global cap stays under that.

import { error, json, preflight } from "../_shared/cors.ts";
import { adminClient, consumeQuota, userClient } from "../_shared/clients.ts";
import { pickVideos, searchQuery } from "./youtube.ts";

const API = "https://www.googleapis.com/youtube/v3";
const CACHE_DAYS = 30;

async function youtube(path: string, params: Record<string, string>, key: string) {
  const url = `${API}/${path}?${new URLSearchParams({ ...params, key })}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) {
    // Don't log the URL: it carries the key.
    const reason = await res.text().then((t) => t.slice(0, 300)).catch(() => "");
    throw new Error(`YouTube ${path} ${res.status}: ${reason}`);
  }
  return res.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return error("POST only", 405);

  const client = userClient(req);
  const { data: auth } = await client.auth.getUser();
  if (!auth.user) return error("Not signed in", 401);

  let body: { recipe_id?: unknown; refresh?: unknown };
  try {
    body = await req.json();
  } catch {
    return error("Invalid JSON");
  }
  const recipeId = typeof body.recipe_id === "string" ? body.recipe_id : "";
  if (!recipeId) return error("recipe_id is required");

  const { data: recipe } = await client
    .from("recipes")
    .select("id, list_id, name, recipe_ingredients(name)")
    .eq("id", recipeId)
    .maybeSingle();
  if (!recipe) return error("Meal not found", 404);

  const { data: cached } = await client
    .from("recipe_videos")
    .select("query_name, videos, fetched_at")
    .eq("recipe_id", recipeId)
    .maybeSingle();
  const fresh = cached && Date.now() - Date.parse(cached.fetched_at) < CACHE_DAYS * 86400e3;
  if (cached && fresh && cached.query_name === recipe.name && body.refresh !== true) {
    return json({ videos: cached.videos, cached: true });
  }

  const key = Deno.env.get("YOUTUBE_API_KEY");
  if (!key) return error("Lamar can't look up videos yet: YouTube isn't set up.", 503);

  const limited = await consumeQuota(auth.user.id, "videos");
  if (limited) return error(limited, 429);

  try {
    const search = await youtube("search", {
      part: "snippet",
      type: "video",
      q: searchQuery(recipe.name),
      maxResults: "12",
      videoEmbeddable: "true",
      safeSearch: "strict",
      relevanceLanguage: "en",
    }, key);
    // deno-lint-ignore no-explicit-any
    const ids = (search.items ?? []).map((i: any) => i?.id?.videoId).filter((x: unknown) => typeof x === "string");
    const details = ids.length
      ? await youtube("videos", { part: "snippet,contentDetails,statistics", id: ids.join(",") }, key)
      : { items: [] };
    const ingredients = (recipe.recipe_ingredients as { name: string }[]).map((i) => i.name);
    const videos = pickVideos(search, details, ingredients, 5, recipe.name);

    const { error: cacheErr } = await adminClient().from("recipe_videos").upsert({
      recipe_id: recipe.id,
      list_id: recipe.list_id,
      query_name: recipe.name,
      videos,
      fetched_at: new Date().toISOString(),
    });
    if (cacheErr) console.warn("find-videos: couldn't cache", cacheErr.message);
    return json({ videos, cached: false });
  } catch (e) {
    console.error("find-videos:", e instanceof Error ? e.message : e);
    return error("Lamar couldn't reach YouTube just now. Try again in a bit.", 502);
  }
});
