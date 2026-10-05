// Pure helpers for find-videos: parsing YouTube Data API responses and
// picking the videos worth showing. No network here, so it's unit-testable.

export type Video = {
  id: string;
  title: string;
  channel: string;
  thumbnail: string;
  seconds: number;
  views: number;
  published_at: string;
};

/** "PT1H2M3S" -> 3723. Unknown formats (e.g. live "P0D") -> 0. */
export function isoDurationSeconds(iso: string | undefined): number {
  const m = /^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/.exec(iso ?? "");
  if (!m) return 0;
  const [, d, h, min, s] = m.map((x) => Number(x ?? 0));
  return d * 86400 + h * 3600 + min * 60 + s;
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** YouTube snippet titles come HTML-escaped ("Mac &amp; Cheese", "Mom&#39;s"). */
export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, e: string) => {
    if (e[0] === "#") {
      const code = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : whole;
    }
    return ENTITIES[e.toLowerCase()] ?? whole;
  });
}

/** What we search YouTube for. */
export function searchQuery(mealName: string): string {
  const name = mealName.trim().replace(/\s+/g, " ").slice(0, 100);
  return /\brecipe\b/i.test(name) ? name : `${name} recipe`;
}

/** Shorts are too thin to cook from; streams and compilations too long. */
export const MIN_SECONDS = 90;
export const MAX_SECONDS = 45 * 60;

// deno-lint-ignore no-explicit-any
type Json = any;

/**
 * Joins search results (ranked by YouTube's relevance) with video details,
 * drops Shorts / very long videos, and nudges up videos whose title mentions
 * the meal's own ingredients. Returns at most [limit].
 */
export function pickVideos(search: Json, details: Json, ingredients: string[], limit = 5): Video[] {
  const byId = new Map<string, Json>();
  for (const d of details?.items ?? []) if (typeof d?.id === "string") byId.set(d.id, d);

  const words = [
    ...new Set(
      ingredients
        .flatMap((i) => i.toLowerCase().split(/[^a-z]+/))
        .filter((w) => w.length >= 4 && !STOP.has(w))
        .map((w) => w.replace(/(es|s)$/, "")),
    ),
  ];

  const scored: { v: Video; score: number }[] = [];
  (search?.items ?? []).forEach((item: Json, rank: number) => {
    const id = item?.id?.videoId;
    const d = byId.get(id);
    if (typeof id !== "string" || !d) return;
    const seconds = isoDurationSeconds(d.contentDetails?.duration);
    if (seconds < MIN_SECONDS || seconds > MAX_SECONDS) return;
    const sn = d.snippet ?? item.snippet ?? {};
    if (sn.liveBroadcastContent && sn.liveBroadcastContent !== "none") return;
    const title = decodeEntities(String(sn.title ?? "")).trim();
    if (!title) return;
    const views = Number(d.statistics?.viewCount ?? 0) || 0;
    const t = title.toLowerCase();
    const mentions = words.filter((w) => t.includes(w)).length;
    // YouTube's order matters most; ingredient mentions and popularity break ties.
    const score = -rank + 1.5 * Math.min(mentions, 3) + Math.log10(views + 1) / 2;
    const thumbs = sn.thumbnails ?? {};
    scored.push({
      score,
      v: {
        id,
        title,
        channel: decodeEntities(String(sn.channelTitle ?? "")).trim(),
        thumbnail: thumbs.high?.url ?? thumbs.medium?.url ?? thumbs.default?.url ?? `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
        seconds,
        views,
        published_at: String(sn.publishedAt ?? ""),
      },
    });
  });
  return scored.sort((a, b) => b.score - a.score).slice(0, limit).map((s) => s.v);
}

const STOP = new Set(["fresh", "large", "small", "ground", "chopped", "dried", "whole", "boneless", "skinless", "about", "with"]);
