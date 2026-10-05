// Minimal FCM HTTP v1 sender authenticated with a Google service account.
//
// FCM_SERVICE_ACCOUNT holds the service-account JSON downloaded from Firebase
// (Project settings → Service accounts → Generate new private key).

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export interface PushMessage {
  token: string;
  title: string;
  body: string;
  data: Record<string, string>;
  /** Replaces an earlier notification with the same tag on the device. */
  collapseKey: string;
}

export type SendResult = "sent" | "unregistered" | "failed";

export function loadServiceAccount(): ServiceAccount | null {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) return null;
  try {
    const sa = JSON.parse(raw) as ServiceAccount;
    if (!sa.project_id || !sa.client_email || !sa.private_key) throw new Error("missing fields");
    return sa;
  } catch (e) {
    console.error("FCM_SERVICE_ACCOUNT is not valid service-account JSON:", (e as Error).message);
    return null;
  }
}

const b64url = (bytes: Uint8Array | string) =>
  btoa(typeof bytes === "string" ? bytes : String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

let cached: { token: string; expires: number } | null = null;

async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.expires > Date.now() + 60_000) return cached.token;

  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const now = Math.floor(Date.now() / 1000);
  const tokenUri = sa.token_uri ?? "https://oauth2.googleapis.com/token";
  const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${
    b64url(JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: tokenUri,
      iat: now,
      exp: now + 3600,
    }))
  }`;
  const sig = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
  );

  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${b64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed (${res.status}): ${await res.text()}`);
  const data = await res.json();
  cached = { token: data.access_token, expires: Date.now() + (data.expires_in ?? 3600) * 1000 };
  return cached.token;
}

export async function send(sa: ServiceAccount, m: PushMessage): Promise<SendResult> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${await accessToken(sa)}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        token: m.token,
        notification: { title: m.title, body: m.body },
        data: m.data,
        android: { priority: "high", notification: { tag: m.collapseKey, sound: "default" } },
        apns: {
          headers: { "apns-collapse-id": m.collapseKey.slice(0, 64) },
          payload: { aps: { sound: "default" } },
        },
      },
    }),
  });
  if (res.ok) return "sent";
  const text = await res.text();
  // The app was uninstalled or the token rotated: forget it.
  if (res.status === 404 || text.includes("UNREGISTERED") || text.includes("registration token is not a valid")) {
    return "unregistered";
  }
  console.error(`FCM send failed (${res.status}): ${text}`);
  return "failed";
}
