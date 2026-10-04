export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Preflight response that allows whatever headers the client library sends. */
export function preflight(req: Request): Response {
  return new Response("ok", {
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Headers":
        req.headers.get("Access-Control-Request-Headers") ?? corsHeaders["Access-Control-Allow-Headers"],
      "Access-Control-Max-Age": "86400",
    },
  });
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function error(message: string, status = 400): Response {
  return json({ error: message }, status);
}
