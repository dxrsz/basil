// Run: node --test supabase/tests/   (Node 23+ runs TypeScript directly)
import { test } from "node:test";
import assert from "node:assert/strict";

import { checkUrl, FetchRefused, isPrivateAddress, parseIPv6, safeFetch } from "../functions/import-items/safe_fetch.ts";

const PUBLIC_V4 = "93.184.215.14";

/** A fake web: hostname -> addresses, and url -> handler. */
function fakeWeb(dns: Record<string, string[]>, pages: Record<string, () => Response>) {
  const fetched: string[] = [];
  return {
    fetched,
    resolve: async (host: string) => {
      if (!(host in dns)) throw new Error("NXDOMAIN");
      return dns[host];
    },
    fetchImpl: (async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      fetched.push(url);
      assert.equal(init?.redirect, "manual", "redirects must be followed by hand");
      const page = pages[url];
      if (!page) return new Response("nope", { status: 404 });
      return page();
    }) as typeof fetch,
  };
}

const html = (body: string, headers: Record<string, string> = {}) => () =>
  new Response(body, { status: 200, headers: { "content-type": "text/html; charset=utf-8", ...headers } });
const redirect = (to: string, status = 302) => () => new Response(null, { status, headers: { location: to } });

async function refused(p: Promise<unknown>, pattern?: RegExp) {
  await assert.rejects(p, (e: unknown) => {
    assert.ok(e instanceof FetchRefused, `expected FetchRefused, got ${e}`);
    if (pattern) assert.match((e as Error).message, pattern);
    return true;
  });
}

// ------------------------------------------------------------- addresses

test("private and special IPv4 addresses are blocked", () => {
  for (const ip of [
    "127.0.0.1",
    "127.255.255.254",
    "10.0.0.1",
    "10.255.255.255",
    "172.16.0.1",
    "172.31.255.255",
    "192.168.1.1",
    "169.254.169.254",
    "169.254.0.1",
    "0.0.0.0",
    "0.1.2.3",
    "100.64.0.1",
    "100.127.255.255",
    "192.0.0.1",
    "192.0.2.5",
    "198.18.0.1",
    "198.19.255.255",
    "198.51.100.7",
    "203.0.113.9",
    "224.0.0.1",
    "239.255.255.250",
    "240.0.0.1",
    "255.255.255.255",
  ]) {
    assert.equal(isPrivateAddress(ip), true, ip);
  }
});

test("public IPv4 addresses are allowed", () => {
  for (const ip of ["8.8.8.8", "1.1.1.1", PUBLIC_V4, "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "11.0.0.1", "169.253.1.1"]) {
    assert.equal(isPrivateAddress(ip), false, ip);
  }
});

test("private and special IPv6 addresses are blocked", () => {
  for (const ip of [
    "::1",
    "::",
    "[::1]",
    "0:0:0:0:0:0:0:1",
    "fc00::1",
    "fd12:3456:789a::1",
    "fe80::1",
    "fe80::1%eth0",
    "febf::1",
    "fec0::1",
    "ff02::1",
    "::ffff:127.0.0.1",
    "::ffff:7f00:1",
    "::ffff:169.254.169.254",
    "::ffff:10.0.0.1",
    "::127.0.0.1",
    "64:ff9b::a9fe:a9fe", // NAT64 of 169.254.169.254
    "64:ff9b::127.0.0.1",
    "2002:7f00:1::1", // 6to4 of 127.0.0.1
    "2002:c0a8:101::1", // 6to4 of 192.168.1.1
    "2001:db8::1",
    "2001:0:4136:e378:8000:63bf:3fff:fdd2", // Teredo
    "100::1",
  ]) {
    assert.equal(isPrivateAddress(ip), true, ip);
  }
});

test("public IPv6 addresses are allowed", () => {
  for (const ip of ["2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8", "64:ff9b::808:808", "2002:808:808::1"]) {
    assert.equal(isPrivateAddress(ip), false, ip);
  }
});

test("garbage addresses are treated as private", () => {
  for (const ip of ["", "localhost", "1.2.3", "1.2.3.256", "::g", "1::2::3", "1:2:3:4:5:6:7:8:9", "example.com"]) {
    assert.equal(isPrivateAddress(ip), true, ip);
  }
});

test("IPv6 parsing handles compression and IPv4 tails", () => {
  assert.deepEqual(parseIPv6("::ffff:127.0.0.1"), [0, 0, 0, 0, 0, 0xffff, 0x7f00, 1]);
  assert.deepEqual(parseIPv6("1::"), [1, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(parseIPv6("1:2:3:4:5:6:7:8"), [1, 2, 3, 4, 5, 6, 7, 8]);
});

// ------------------------------------------------------------------- URLs

test("checkUrl rejects bad schemes, ports, credentials and internal hosts", () => {
  for (const url of [
    "file:///etc/passwd",
    "ftp://example.com/",
    "gopher://example.com/",
    "javascript:alert(1)",
    "data:text/html,hi",
    "http://localhost/",
    "http://LOCALHOST./",
    "http://foo.localhost/",
    "http://printer.local/",
    "http://metadata.google.internal/",
    "http://metadata/",
    "http://127.0.0.1/",
    "http://127.1/",
    "http://2130706433/", // 127.0.0.1 as a decimal
    "http://0x7f.0.0.1/",
    "http://017700000001/", // octal
    "http://0.0.0.0/",
    "http://169.254.169.254/latest/meta-data/",
    "http://[::1]/",
    "http://[::ffff:127.0.0.1]/",
    "http://[fd00::1]/",
    "http://example.com:8080/",
    "https://example.com:22/",
    "http://user:pass@example.com/",
    "not a url",
  ]) {
    assert.throws(() => checkUrl(url), FetchRefused, url);
  }
});

test("checkUrl accepts normal web links", () => {
  for (const url of ["https://example.com/recipe", "http://example.com:80/x", "https://www.example.co.uk:443/a?b=c", `http://${PUBLIC_V4}/`]) {
    assert.doesNotThrow(() => checkUrl(url), url);
  }
});

// ------------------------------------------------------------------ fetch

test("fetches a public page", async () => {
  const web = fakeWeb({ "example.com": [PUBLIC_V4] }, { "https://example.com/r": html("<h1>Hi</h1>") });
  const page = await safeFetch("https://example.com/r", web);
  assert.equal(page.body, "<h1>Hi</h1>");
  assert.equal(page.url, "https://example.com/r");
});

test("refuses hosts that resolve to private addresses (DNS-level)", async () => {
  for (const addrs of [["127.0.0.1"], ["10.1.2.3"], ["169.254.169.254"], ["::1"], ["fd00::5"], [PUBLIC_V4, "192.168.0.1"]]) {
    const web = fakeWeb({ "evil.example": addrs }, { "https://evil.example/": html("secret") });
    await refused(safeFetch("https://evil.example/", web), /can't open/);
    assert.equal(web.fetched.length, 0, `connected despite ${addrs}`);
  }
});

test("refuses unresolvable hosts", async () => {
  const web = fakeWeb({ "empty.example": [] }, {});
  await refused(safeFetch("https://nowhere.example/", web), /couldn't find/);
  await refused(safeFetch("https://empty.example/", web), /couldn't find/);
});

test("follows a redirect to another public page", async () => {
  const web = fakeWeb(
    { "a.example": [PUBLIC_V4], "b.example": [PUBLIC_V4] },
    { "https://a.example/": redirect("https://b.example/final"), "https://b.example/final": html("ok") },
  );
  const page = await safeFetch("https://a.example/", web);
  assert.equal(page.body, "ok");
  assert.equal(page.url, "https://b.example/final");
});

test("resolves relative redirects", async () => {
  const web = fakeWeb(
    { "a.example": [PUBLIC_V4] },
    { "https://a.example/old": redirect("/new", 301), "https://a.example/new": html("moved") },
  );
  assert.equal((await safeFetch("https://a.example/old", web)).body, "moved");
});

test("refuses redirects to private addresses, internal hosts and odd schemes", async () => {
  for (const target of [
    "http://169.254.169.254/latest/meta-data/",
    "http://127.0.0.1/admin",
    "http://[::1]/",
    "http://localhost:8080/",
    "http://internal.example/",
    "file:///etc/passwd",
    "http://a.example:6379/",
  ]) {
    const web = fakeWeb(
      { "a.example": [PUBLIC_V4], "internal.example": ["10.0.0.7"] },
      { "https://a.example/": redirect(target), [target]: html("secret") },
    );
    await refused(safeFetch("https://a.example/", web));
    assert.deepEqual(web.fetched, ["https://a.example/"], `followed redirect to ${target}`);
  }
});

test("refuses a redirect chain that ends somewhere private", async () => {
  const web = fakeWeb(
    { "a.example": [PUBLIC_V4], "b.example": [PUBLIC_V4], "c.example": ["192.168.1.10"] },
    {
      "https://a.example/": redirect("https://b.example/"),
      "https://b.example/": redirect("https://c.example/"),
      "https://c.example/": html("secret"),
    },
  );
  await refused(safeFetch("https://a.example/", web), /can't open/);
  assert.deepEqual(web.fetched, ["https://a.example/", "https://b.example/"]);
});

test("caps the number of redirects", async () => {
  const pages: Record<string, () => Response> = {};
  for (let i = 0; i < 10; i++) pages[`https://a.example/${i}`] = redirect(`https://a.example/${i + 1}`);
  const web = fakeWeb({ "a.example": [PUBLIC_V4] }, pages);
  await refused(safeFetch("https://a.example/0", { ...web, maxRedirects: 3 }), /too many/);
  assert.equal(web.fetched.length, 4);
});

test("refuses oversized bodies by Content-Length", async () => {
  const web = fakeWeb({ "a.example": [PUBLIC_V4] }, { "https://a.example/": html("x", { "content-length": "999999999" }) });
  await refused(safeFetch("https://a.example/", { ...web, maxBytes: 1000 }), /too big/);
});

test("refuses oversized streamed bodies without Content-Length", async () => {
  let pulled = 0;
  const stream = () =>
    new Response(
      new ReadableStream({
        pull(c) {
          pulled++;
          c.enqueue(new Uint8Array(4096).fill(65));
          if (pulled > 10_000) c.close();
        },
      }),
      { status: 200, headers: { "content-type": "text/html" } },
    );
  const web = fakeWeb({ "a.example": [PUBLIC_V4] }, { "https://a.example/": stream });
  await refused(safeFetch("https://a.example/", { ...web, maxBytes: 50_000 }), /too big/);
  assert.ok(pulled < 100, `read ${pulled} chunks; should stop soon after the cap`);
});

test("accepts a body exactly at the cap", async () => {
  const web = fakeWeb({ "a.example": [PUBLIC_V4] }, { "https://a.example/": html("a".repeat(1000)) });
  assert.equal((await safeFetch("https://a.example/", { ...web, maxBytes: 1000 })).body.length, 1000);
});

test("only text/html and JSON content types are read", async () => {
  for (const [type, ok] of [
    ["text/html", true],
    ["text/html; charset=ISO-8859-1", true],
    ["application/xhtml+xml", true],
    ["application/json", true],
    ["application/ld+json", true],
    ["image/png", false],
    ["application/octet-stream", false],
    ["application/pdf", false],
    ["text/plain", false],
    ["", false],
  ] as const) {
    const web = fakeWeb(
      { "a.example": [PUBLIC_V4] },
      { "https://a.example/": () => new Response("{}", { status: 200, headers: type ? { "content-type": type } : {} }) },
    );
    const p = safeFetch("https://a.example/", web);
    if (ok) await p;
    else await refused(p, /isn't a web page/);
  }
});

test("times out slow servers", async () => {
  const web = fakeWeb({ "a.example": [PUBLIC_V4] }, {});
  const slow = ((_: unknown, init?: RequestInit) =>
    new Promise((_, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    })) as typeof fetch;
  const started = Date.now();
  await refused(safeFetch("https://a.example/", { ...web, fetchImpl: slow, timeoutMs: 50 }), /too long/);
  assert.ok(Date.now() - started < 2000);
});

test("non-2xx responses are refused", async () => {
  const web = fakeWeb({ "a.example": [PUBLIC_V4] }, { "https://a.example/": () => new Response("x", { status: 403 }) });
  await refused(safeFetch("https://a.example/", web), /403/);
});

test("decodes the declared charset", async () => {
  const latin1 = new Uint8Array([0x63, 0x72, 0xe8, 0x6d, 0x65]); // "crème" in ISO-8859-1
  const web = fakeWeb(
    { "a.example": [PUBLIC_V4] },
    { "https://a.example/": () => new Response(latin1, { headers: { "content-type": "text/html; charset=iso-8859-1" } }) },
  );
  assert.equal((await safeFetch("https://a.example/", web)).body, "crème");
});
