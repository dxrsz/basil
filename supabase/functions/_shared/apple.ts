// Sign in with Apple server-side helpers: a client secret signed on demand
// from the .p8 key (so there's no 6-month expiry to remember here), turning
// an authorization code into a refresh token, and revoking tokens when an
// account is deleted (Apple requires apps to revoke on deletion).
//
// Secrets: APPLE_SIWA_P8 (the key file's contents), APPLE_SIWA_KEY_ID,
// APPLE_TEAM_ID.

const b64url = (bytes: Uint8Array | string) =>
  btoa(typeof bytes === "string" ? bytes : String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function signingKey(): Promise<CryptoKey> {
  const pem = Deno.env.get("APPLE_SIWA_P8");
  if (!pem) throw new Error("APPLE_SIWA_P8 is not set");
  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** ES256 client secret for [clientId] (the bundle ID or the Services ID). */
export async function clientSecret(clientId: string): Promise<string> {
  const keyId = Deno.env.get("APPLE_SIWA_KEY_ID"), teamId = Deno.env.get("APPLE_TEAM_ID");
  if (!keyId || !teamId) throw new Error("APPLE_SIWA_KEY_ID / APPLE_TEAM_ID are not set");
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({ iss: teamId, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: clientId }));
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey(),
    new TextEncoder().encode(`${header}.${payload}`),
  );
  return `${header}.${payload}.${b64url(new Uint8Array(sig))}`;
}

async function post(path: string, form: Record<string, string>): Promise<Response> {
  return fetch(`https://appleid.apple.com${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form),
    signal: AbortSignal.timeout(8000),
  });
}

/** Authorization code (from the native sign-in sheet) → refresh token. */
export async function refreshTokenFromCode(code: string, clientId: string): Promise<string> {
  const res = await post("/auth/token", {
    client_id: clientId,
    client_secret: await clientSecret(clientId),
    code,
    grant_type: "authorization_code",
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || typeof body.refresh_token !== "string") {
    throw new Error(`Apple token exchange failed (${res.status}): ${body.error ?? "no refresh_token"}`);
  }
  return body.refresh_token;
}

/** Revokes a refresh token. Apple answers 200 even for unknown tokens. */
export async function revoke(refreshToken: string, clientId: string): Promise<void> {
  const res = await post("/auth/revoke", {
    client_id: clientId,
    client_secret: await clientSecret(clientId),
    token: refreshToken,
    token_type_hint: "refresh_token",
  });
  if (!res.ok) throw new Error(`Apple revoke failed (${res.status}): ${await res.text()}`);
}
