// Fetches a user-supplied URL without letting it reach anything private.
//
// Every hop (the first URL and each redirect) is checked before we connect:
// only http/https on the default ports, no credentials, no internal-looking
// hostnames, and every address the host resolves to must be public unicast.
// Redirects are followed by hand so each Location gets the same check.
// Responses are capped in time, size and content type.
//
// Residual risk: fetch() does its own DNS lookup after ours, so a rebinding
// DNS server could answer differently the second time. The redirect, port and
// literal-address checks don't depend on DNS, and nothing from the page is
// ever returned to the caller verbatim (only schema-constrained model output).
//
// Pure TypeScript with injected DNS/fetch so it's testable under Node.

/** A refusal or failure that is safe (and friendly) to show the user. */
export class FetchRefused extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FetchRefused";
  }
}

export type Resolver = (hostname: string) => Promise<string[]>;

export type SafeFetchOptions = {
  resolve: Resolver;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  maxBytes?: number;
  maxRedirects?: number;
  userAgent?: string;
};

export type FetchedPage = { url: string; contentType: string; body: string };

const ALLOWED_TYPES = ["text/html", "application/xhtml+xml", "application/json", "application/ld+json"];

const BLOCKED_HOST_SUFFIXES = [".localhost", ".local", ".internal", ".intranet", ".lan", ".home.arpa", ".corp"];

// ------------------------------------------------------------------ addresses

/** Parses dotted-quad IPv4 into four octets, or null. */
export function parseIPv4(s: string): number[] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (!m) return null;
  const parts = m.slice(1).map(Number);
  return parts.every((p) => p <= 255) ? parts : null;
}

/** Parses IPv6 (with optional embedded IPv4 tail and zone) into 8 hextets, or null. */
export function parseIPv6(input: string): number[] | null {
  let s = input.replace(/^\[|\]$/g, "").toLowerCase();
  const zone = s.indexOf("%");
  if (zone >= 0) s = s.slice(0, zone);
  if (!/^[0-9a-f:.]+$/.test(s) || !s.includes(":")) return null;

  // Embedded IPv4 tail, e.g. ::ffff:127.0.0.1
  const tail: number[] = [];
  const lastColon = s.lastIndexOf(":");
  const last = s.slice(lastColon + 1);
  if (last.includes(".")) {
    const v4 = parseIPv4(last);
    if (!v4) return null;
    tail.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
    s = s.slice(0, lastColon + 1) + "0:0"; // two placeholder groups, replaced below
  }

  const halves = s.split("::");
  if (halves.length > 2) return null;
  const parse = (part: string) => (part === "" ? [] : part.split(":"));
  const head = parse(halves[0]);
  const rest = halves.length === 2 ? parse(halves[1]) : [];
  for (const h of [...head, ...rest]) {
    if (!/^[0-9a-f]{1,4}$/.test(h)) return null;
  }
  let groups: number[];
  if (halves.length === 2) {
    const missing = 8 - head.length - rest.length;
    if (missing < 1) return null;
    groups = [...head.map((h) => parseInt(h, 16)), ...Array(missing).fill(0), ...rest.map((h) => parseInt(h, 16))];
  } else {
    groups = head.map((h) => parseInt(h, 16));
  }
  if (groups.length !== 8) return null;
  if (tail.length) groups.splice(6, 2, ...tail);
  return groups;
}

function isPrivateIPv4([a, b, c]: number[]): boolean {
  return (
    a === 0 || // "this network", incl. 0.0.0.0
    a === 10 ||
    (a === 100 && b >= 64 && b <= 127) || // carrier-grade NAT
    a === 127 ||
    (a === 169 && b === 254) || // link-local, cloud metadata
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && c === 0) || // IETF protocol assignments
    (a === 192 && b === 0 && c === 2) || // TEST-NET-1
    (a === 192 && b === 88 && c === 99) || // 6to4 relay
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) || // benchmarking
    (a === 198 && b === 51 && c === 100) || // TEST-NET-2
    (a === 203 && b === 0 && c === 113) || // TEST-NET-3
    a >= 224 // multicast, reserved, broadcast
  );
}

function v4FromHextets(hi: number, lo: number): number[] {
  return [hi >> 8, hi & 0xff, lo >> 8, lo & 0xff];
}

function isPrivateIPv6(g: number[]): boolean {
  // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d): judge the IPv4.
  if (g.slice(0, 5).every((x) => x === 0) && (g[5] === 0xffff || g[5] === 0)) {
    if (g[5] === 0 && g[6] === 0) return true; // ::, ::1 and friends
    return isPrivateIPv4(v4FromHextets(g[6], g[7]));
  }
  // NAT64 well-known prefix 64:ff9b::/96 embeds an IPv4.
  if (g[0] === 0x64 && g[1] === 0xff9b && g.slice(2, 6).every((x) => x === 0)) {
    return isPrivateIPv4(v4FromHextets(g[6], g[7]));
  }
  // Only global unicast (2000::/3) is allowed at all; this rejects
  // fc00::/7 (ULA), fe80::/10 (link-local), fec0::/10, ff00::/8 (multicast) etc.
  if ((g[0] & 0xe000) !== 0x2000) return true;
  if (g[0] === 0x2001 && g[1] === 0x0db8) return true; // documentation
  if (g[0] === 0x2001 && g[1] === 0) return true; // Teredo (embeds obfuscated IPv4)
  if (g[0] === 0x2002) return isPrivateIPv4(v4FromHextets(g[1], g[2])); // 6to4
  return false;
}

/** True for any address we must never connect to (or anything we can't parse). */
export function isPrivateAddress(ip: string): boolean {
  const v4 = parseIPv4(ip);
  if (v4) return isPrivateIPv4(v4);
  const v6 = parseIPv6(ip);
  if (v6) return isPrivateIPv6(v6);
  return true;
}

// ----------------------------------------------------------------------- URLs

/** Static checks that don't need DNS. Returns the parsed URL or throws FetchRefused. */
export function checkUrl(raw: string | URL): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new FetchRefused("That doesn't look like a web link.");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new FetchRefused("Lamar can only open http and https links.");
  }
  if (url.username || url.password) throw new FetchRefused("Lamar can't open links with passwords in them.");
  // URL normalises default ports to "", so this allows only :80 for http and :443 for https.
  if (url.port !== "") throw new FetchRefused("Lamar can only open regular web links.");

  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host) throw new FetchRefused("That doesn't look like a web link.");
  if (host.startsWith("[") || parseIPv4(host)) {
    if (isPrivateAddress(host)) throw new FetchRefused("Lamar can't open that address.");
  } else if (
    host === "localhost" ||
    !host.includes(".") ||
    BLOCKED_HOST_SUFFIXES.some((s) => host.endsWith(s)) ||
    host === "metadata.google.internal"
  ) {
    throw new FetchRefused("Lamar can't open that address.");
  }
  return url;
}

async function checkResolved(url: URL, resolve: Resolver): Promise<void> {
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (parseIPv4(host) || parseIPv6(host)) return; // literal, already checked
  let addrs: string[];
  try {
    addrs = await resolve(host);
  } catch {
    throw new FetchRefused("Lamar couldn't find that website.");
  }
  if (addrs.length === 0) throw new FetchRefused("Lamar couldn't find that website.");
  if (addrs.some(isPrivateAddress)) throw new FetchRefused("Lamar can't open that address.");
}

// ---------------------------------------------------------------------- fetch

function charsetOf(contentType: string): string {
  const m = /charset\s*=\s*"?([\w-]+)"?/i.exec(contentType);
  return m ? m[1].toLowerCase() : "utf-8";
}

async function readCapped(res: Response, maxBytes: number): Promise<Uint8Array> {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    await res.body?.cancel().catch(() => {});
    throw new FetchRefused("That page is too big for Lamar to read.");
  }
  if (!res.body) return new Uint8Array();
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new FetchRefused("That page is too big for Lamar to read.");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

export async function safeFetch(rawUrl: string, opts: SafeFetchOptions): Promise<FetchedPage> {
  const {
    resolve,
    fetchImpl = fetch,
    timeoutMs = 8000,
    maxBytes = 2 * 1024 * 1024,
    maxRedirects = 4,
    userAgent = "Mozilla/5.0 (compatible; LamarsGroceries/1.0; +https://lamarsgroceries.app)",
  } = opts;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    let url = checkUrl(rawUrl);
    for (let hop = 0; ; hop++) {
      await checkResolved(url, resolve);
      let res: Response;
      try {
        res = await fetchImpl(url.toString(), {
          method: "GET",
          redirect: "manual",
          signal: controller.signal,
          headers: {
            "User-Agent": userAgent,
            Accept: "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.1",
            "Accept-Language": "en",
          },
        });
      } catch {
        if (controller.signal.aborted) throw new FetchRefused("That page took too long to load.");
        throw new FetchRefused("Lamar couldn't load that page.");
      }

      if (res.status >= 300 && res.status < 400) {
        const location = res.headers.get("location");
        await res.body?.cancel().catch(() => {});
        if (!location) throw new FetchRefused("Lamar couldn't load that page.");
        if (hop >= maxRedirects) throw new FetchRefused("That link redirects too many times.");
        url = checkUrl(new URL(location, url));
        continue;
      }
      if (!res.ok) {
        await res.body?.cancel().catch(() => {});
        if ([401, 403, 429, 503].includes(res.status)) {
          throw new FetchRefused(
            `That site wouldn't let Lamar in (error ${res.status}). Try copying the ingredients and pasting them instead.`,
          );
        }
        throw new FetchRefused(`That page wouldn't open (error ${res.status}).`);
      }

      const contentType = (res.headers.get("content-type") ?? "").toLowerCase();
      if (!ALLOWED_TYPES.some((t) => contentType.startsWith(t))) {
        await res.body?.cancel().catch(() => {});
        throw new FetchRefused("That link isn't a web page Lamar can read.");
      }

      const bytes = await readCapped(res, maxBytes);
      let decoder: TextDecoder;
      try {
        decoder = new TextDecoder(charsetOf(contentType));
      } catch {
        decoder = new TextDecoder("utf-8");
      }
      return { url: url.toString(), contentType, body: decoder.decode(bytes) };
    }
  } catch (e) {
    if (e instanceof FetchRefused) throw e;
    if (controller.signal.aborted) throw new FetchRefused("That page took too long to load.");
    throw new FetchRefused("Lamar couldn't load that page.");
  } finally {
    clearTimeout(timer);
  }
}
