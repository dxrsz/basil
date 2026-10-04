// Generates a photo of the finished meal, reflecting its chosen ingredients.
//
// POST { recipe_id: string, force?: boolean } -> { status: "generating" | "ready" }
//
// Returns immediately; generation continues in the background and the result
// reaches clients through realtime updates on the `recipes` row.

import { corsHeaders, error, json } from "../_shared/cors.ts";
import { adminClient, userClient } from "../_shared/clients.ts";
import { generateImage } from "../_shared/openai.ts";

const BUCKET = "recipe-images";

async function signatureOf(name: string, ingredients: string[]): Promise<string> {
  const canonical = [name.trim().toLowerCase(), ...ingredients.map((i) => i.trim().toLowerCase()).sort()]
    .join("|");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function promptFor(name: string, ingredients: string[]): string {
  const featured = ingredients.length
    ? `The dish is made with: ${ingredients.join(", ")}. Make these ingredients visibly recognisable in the dish, and don't add prominent ingredients that aren't listed.`
    : "";
  return [
    `An appetising, realistic overhead food photograph of a home-cooked "${name}", plated and ready to eat.`,
    featured,
    "Natural window light, shallow depth of field, a simple ceramic plate or bowl on a warm wooden table, a little garnish.",
    "No text, no labels, no hands, no people.",
  ].filter(Boolean).join(" ");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("POST only", 405);

  let body: { recipe_id?: string; force?: boolean };
  try {
    body = await req.json();
  } catch {
    return error("Invalid JSON");
  }
  if (!body.recipe_id) return error("recipe_id is required");

  // Read through the user's client: RLS guarantees they're a member of the list.
  const user = userClient(req);
  const { data: recipe, error: readErr } = await user
    .from("recipes")
    .select("id, list_id, name, image_url, image_status, image_signature, recipe_ingredients(name, position)")
    .eq("id", body.recipe_id)
    .maybeSingle();
  if (readErr) return error(readErr.message, 500);
  if (!recipe) return error("Recipe not found", 404);

  const ingredients = (recipe.recipe_ingredients as { name: string; position: number }[])
    .sort((a, b) => a.position - b.position)
    .map((i) => i.name);
  const signature = await signatureOf(recipe.name, ingredients);

  if (!body.force && recipe.image_signature === signature && recipe.image_status !== "failed") {
    return json({ status: recipe.image_status });
  }

  const admin = adminClient();
  await admin
    .from("recipes")
    .update({ image_status: "generating", image_signature: signature })
    .eq("id", recipe.id);

  const work = (async () => {
    try {
      const png = await generateImage(promptFor(recipe.name, ingredients));
      const path = `${recipe.list_id}/${recipe.id}/${crypto.randomUUID()}.png`;
      const { error: upErr } = await admin.storage.from(BUCKET).upload(path, png, {
        contentType: "image/png",
        cacheControl: "31536000",
      });
      if (upErr) throw upErr;
      const { data: pub } = admin.storage.from(BUCKET).getPublicUrl(path);

      // If the recipe changed again while we were generating, a newer request
      // owns the row now; drop this image rather than clobbering it.
      const { data: updated } = await admin
        .from("recipes")
        .update({ image_url: pub.publicUrl, image_status: "ready" })
        .eq("id", recipe.id)
        .eq("image_signature", signature)
        .select("id");
      if (!updated?.length) {
        await admin.storage.from(BUCKET).remove([path]);
        return;
      }

      // Clean up the previous image.
      const prefix = `/object/public/${BUCKET}/`;
      if (recipe.image_url?.includes(prefix)) {
        const oldPath = recipe.image_url.split(prefix)[1];
        if (oldPath && oldPath !== path) await admin.storage.from(BUCKET).remove([oldPath]);
      }
    } catch (e) {
      console.error("image generation failed", e);
      await admin
        .from("recipes")
        .update({ image_status: "failed" })
        .eq("id", recipe.id)
        .eq("image_signature", signature);
    }
  })();

  // Keep the worker alive after responding.
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(work) ?? (await work);

  return json({ status: "generating" }, 202);
});
