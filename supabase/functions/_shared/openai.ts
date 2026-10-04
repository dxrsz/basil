const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
export const TEXT_MODEL = Deno.env.get("OPENAI_TEXT_MODEL") ?? "gpt-5-mini";
export const IMAGE_MODEL = Deno.env.get("OPENAI_IMAGE_MODEL") ?? "gpt-image-1";

async function openai(path: string, body: unknown): Promise<any> {
  if (!OPENAI_API_KEY) throw new Error("OPENAI_API_KEY is not set");
  const res = await fetch(`https://api.openai.com/v1/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`OpenAI ${path} failed (${res.status}): ${await res.text()}`);
  }
  return res.json();
}

/** Chat completion constrained to a JSON schema; returns the parsed object. */
export async function structured<T>(
  system: string,
  user: string,
  schemaName: string,
  schema: Record<string, unknown>,
): Promise<T> {
  const data = await openai("chat/completions", {
    model: TEXT_MODEL,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
    response_format: {
      type: "json_schema",
      json_schema: { name: schemaName, strict: true, schema },
    },
  });
  const content = data.choices?.[0]?.message?.content;
  if (!content) throw new Error("OpenAI returned no content");
  return JSON.parse(content) as T;
}

/** Generates one square image and returns its PNG bytes. */
export async function generateImage(prompt: string): Promise<Uint8Array> {
  const data = await openai("images/generations", {
    model: IMAGE_MODEL,
    prompt,
    size: "1024x1024",
    quality: "medium",
    n: 1,
  });
  const b64 = data.data?.[0]?.b64_json;
  if (!b64) throw new Error("OpenAI returned no image");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}
