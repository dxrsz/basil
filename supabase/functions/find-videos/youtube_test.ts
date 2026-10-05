import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeEntities, isoDurationSeconds, pickVideos, searchQuery } from "./youtube.ts";

test("iso durations", () => {
  assert.equal(isoDurationSeconds("PT12M3S"), 723);
  assert.equal(isoDurationSeconds("PT1H2M3S"), 3723);
  assert.equal(isoDurationSeconds("PT45S"), 45);
  assert.equal(isoDurationSeconds("P0D"), 0);
  assert.equal(isoDurationSeconds(undefined), 0);
});

test("entities in titles", () => {
  assert.equal(decodeEntities("Mac &amp; Cheese"), "Mac & Cheese");
  assert.equal(decodeEntities("Mom&#39;s &quot;best&quot; tacos"), `Mom's "best" tacos`);
  assert.equal(decodeEntities("Caf&#xe9;"), "Café");
  assert.equal(decodeEntities("A &bogus; thing"), "A &bogus; thing");
});

test("search query", () => {
  assert.equal(searchQuery("  Taco   bowls "), "Taco bowls recipe");
  assert.equal(searchQuery("Best pancake recipe"), "Best pancake recipe");
});

const s = (id: string, title: string) => ({ id: { videoId: id }, snippet: { title, channelTitle: "Chef", thumbnails: {} } });
const d = (id: string, duration: string, views: number, title?: string) => ({
  id,
  contentDetails: { duration },
  statistics: { viewCount: String(views) },
  snippet: { title: title ?? id, channelTitle: "Chef &amp; Co", liveBroadcastContent: "none", publishedAt: "2024-01-01T00:00:00Z", thumbnails: { high: { url: `https://i.ytimg.com/${id}.jpg` } } },
});

test("drops shorts, very long videos and live streams; keeps YouTube's order otherwise", () => {
  const search = { items: [s("a", "A"), s("short", "S"), s("b", "B"), s("long", "L"), s("live", "Live"), s("c", "C")] };
  const details = {
    items: [
      d("a", "PT8M", 1000),
      d("short", "PT40S", 9e6),
      d("b", "PT12M", 1000),
      d("long", "PT2H", 1000),
      { ...d("live", "PT10M", 1000), snippet: { ...d("live", "PT10M", 1).snippet, liveBroadcastContent: "live" } },
      d("c", "PT5M", 1000),
    ],
  };
  const v = pickVideos(search, details, []);
  assert.deepEqual(v.map((x) => x.id), ["a", "b", "c"]);
  assert.equal(v[0].channel, "Chef & Co");
  assert.equal(v[0].seconds, 480);
  assert.equal(v[0].thumbnail, "https://i.ytimg.com/a.jpg");
});

test("videos mentioning the meal's ingredients move up", () => {
  const search = { items: [s("plain", "x"), s("salmon", "x")] };
  const details = {
    items: [d("plain", "PT8M", 5000, "Easy power bowl"), d("salmon", "PT8M", 5000, "Salmon & edamame power bowl")],
  };
  const v = pickVideos(search, details, ["Salmon fillets", "Edamame", "Jasmine rice"]);
  assert.deepEqual(v.map((x) => x.id), ["salmon", "plain"]);
});

test("limit and missing details", () => {
  const search = { items: [s("a", "A"), s("ghost", "G"), s("b", "B")] };
  const details = { items: [d("a", "PT8M", 1), d("b", "PT8M", 1)] };
  assert.deepEqual(pickVideos(search, details, [], 1).map((x) => x.id), ["a"]);
  assert.deepEqual(pickVideos({}, {}, []), []);
});
