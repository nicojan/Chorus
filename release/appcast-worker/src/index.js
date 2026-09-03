// Chorus appcast feed — Cloudflare Worker.
//
// Serves the Sparkle appcast at https://updates.nicojan.com/chorus/appcast.xml
// and counts how many distinct installations ask for it each day. Sparkle
// checks once every 24 hours (SUScheduledCheckInterval in Info.plist), so the
// daily count is a daily-active-users figure.
//
// The XML itself still comes from docs/appcast.xml in the Chorus repo, served
// by GitHub Pages. This Worker proxies it, so the release process does not
// change: commit the appcast, Pages republishes, the Worker picks it up.
//
// RULE: counting must never break an update check. Every KV call runs after
// the response is already on its way and swallows its own errors. A user whose
// ping is not counted still gets their update.

const UPSTREAM = "https://nicojan.github.io/Chorus/appcast.xml";

// How long a per-installation marker lives. Two days, so a rollup that runs
// after midnight can still see yesterday's markers.
const MARKER_TTL_SECONDS = 60 * 60 * 48;

// Aggregates are kept in one key so a day costs one read and one write.
const AGGREGATE_KEY = "agg:daily";
const AGGREGATE_MAX_DAYS = 400;

const VERSION_PATTERN = /^[0-9A-Za-z._-]{1,24}$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/chorus/appcast.xml") {
      return handleAppcast(request, env, ctx);
    }
    if (url.pathname === "/chorus/stats.json") {
      return handleStats(request, env);
    }
    if (url.pathname === "/") {
      return new Response("Update feeds for nicojan's apps.\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    return new Response("Not found\n", {
      status: 404,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(rollUpDay(env, previousDay(new Date(event.scheduledTime))));
  },
};

// --- serving -----------------------------------------------------------

async function handleAppcast(request, env, ctx) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed\n", {
      status: 405,
      headers: { allow: "GET, HEAD" },
    });
  }

  // Count first (as a promise), so a slow upstream does not delay the write.
  ctx.waitUntil(recordPing(request, env));

  let upstream;
  try {
    upstream = await fetch(UPSTREAM, {
      cf: { cacheTtl: 300, cacheEverything: true },
      headers: { "user-agent": "chorus-appcast-worker" },
    });
  } catch (error) {
    return new Response("Update feed unavailable\n", {
      status: 502,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  if (!upstream.ok) {
    return new Response("Update feed unavailable\n", {
      status: 502,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  const headers = new Headers({
    "content-type": "application/xml; charset=utf-8",
    "cache-control": "public, max-age=300",
  });
  return new Response(upstream.body, { status: 200, headers });
}

// --- counting ----------------------------------------------------------

// One KV key per installation per day. The key holds no address and no
// identifier that survives the day: it is a hash of the address, the
// user-agent, the date and a secret salt, so the same machine hashes to an
// unrelated value tomorrow and the value cannot be turned back into an address.
async function recordPing(request, env) {
  try {
    const day = dayStamp(new Date());
    const version = versionFromUserAgent(request.headers.get("user-agent"));
    const address = normalizeAddress(request.headers.get("cf-connecting-ip"));
    const marker = await installationHash(env.PING_SALT, day, address, request.headers.get("user-agent") || "");
    const key = `u:${day}:${version}:${marker}`;

    // Read before writing: KV allows far more reads than writes per day, and a
    // machine that already pinged today must not spend a second write.
    const seen = await env.PINGS.get(key);
    if (seen === null) {
      await env.PINGS.put(key, "1", { expirationTtl: MARKER_TTL_SECONDS });
    }
  } catch (error) {
    // Counting is best-effort. Never surface this.
  }
}

// IPv6 privacy extensions rotate the host half of the address every day or so,
// which is the same cadence Sparkle checks on: left alone, one machine would
// look like a new one each time it rotated and inflate the count. Only the /64
// network prefix is stable, so that is what gets hashed. IPv4 addresses are
// already stable and pass through whole.
//
// The cost is that machines sharing a /64 count once, which is what already
// happens to machines sharing an IPv4 address behind NAT.
export function normalizeAddress(address) {
  if (!address) {
    return "";
  }
  if (!address.includes(":")) {
    return address;
  }

  const bare = address.split("%")[0].toLowerCase();
  const [head, tail] = bare.split("::");
  const headGroups = head ? head.split(":") : [];
  const tailGroups = tail ? tail.split(":") : [];

  const groups = bare.includes("::")
    ? [
        ...headGroups,
        ...new Array(Math.max(8 - headGroups.length - tailGroups.length, 0)).fill("0"),
        ...tailGroups,
      ]
    : bare.split(":");

  return groups
    .slice(0, 4)
    .map((group) => (group === "" ? "0" : group))
    .join(":") + "::/64";
}

async function installationHash(salt, day, address, userAgent) {
  const material = `${salt || "unsalted"}:${day}:${address}:${userAgent}`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return [...new Uint8Array(digest)]
    .slice(0, 16)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function versionFromUserAgent(userAgent) {
  // Sparkle sends "Chorus/1.5.19 Sparkle/2.6.4".
  const match = /^Chorus\/([^\s]+)/.exec(userAgent || "");
  const candidate = match ? match[1] : "unknown";
  return VERSION_PATTERN.test(candidate) ? candidate : "unknown";
}

// --- rollup ------------------------------------------------------------

// Walks one day's markers, writes the totals into the aggregate, and lets the
// markers expire on their own. Returns the day's record.
async function rollUpDay(env, day) {
  const byVersion = await countMarkers(env, `u:${day}:`);
  const total = Object.values(byVersion).reduce((sum, count) => sum + count, 0);
  const record = { day, total, byVersion };

  const existing = await readAggregate(env);
  const merged = { ...existing, [day]: record };
  const trimmed = Object.fromEntries(
    Object.entries(merged)
      .sort(([a], [b]) => (a < b ? 1 : -1))
      .slice(0, AGGREGATE_MAX_DAYS)
  );

  await env.PINGS.put(AGGREGATE_KEY, JSON.stringify(trimmed));
  return record;
}

async function countMarkers(env, prefix) {
  const counts = {};
  let cursor = undefined;

  for (;;) {
    const page = await env.PINGS.list({ prefix, cursor, limit: 1000 });
    for (const entry of page.keys) {
      const version = entry.name.slice(prefix.length).split(":")[0] || "unknown";
      counts[version] = (counts[version] || 0) + 1;
    }
    if (page.list_complete) {
      return counts;
    }
    cursor = page.cursor;
  }
}

async function readAggregate(env) {
  const stored = await env.PINGS.get(AGGREGATE_KEY, { type: "json" });
  return stored && typeof stored === "object" ? stored : {};
}

// --- stats -------------------------------------------------------------

async function handleStats(request, env) {
  const offered = request.headers.get("authorization") || "";
  const expected = `Bearer ${env.STATS_TOKEN || ""}`;
  if (!env.STATS_TOKEN || !timingSafeEqual(offered, expected)) {
    return new Response("Unauthorized\n", {
      status: 401,
      headers: { "www-authenticate": "Bearer" },
    });
  }

  const aggregate = await readAggregate(env);
  const days = Object.values(aggregate).sort((a, b) => (a.day < b.day ? 1 : -1));

  // Today is still accumulating and has no rolled-up record yet, so count it live.
  const today = dayStamp(new Date());
  if (!aggregate[today]) {
    const byVersion = await countMarkers(env, `u:${today}:`);
    const total = Object.values(byVersion).reduce((sum, count) => sum + count, 0);
    days.unshift({ day: today, total, byVersion, partial: true });
  }

  return new Response(JSON.stringify({ days }, null, 2), {
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  let difference = 0;
  for (let i = 0; i < a.length; i += 1) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}

// --- dates -------------------------------------------------------------

function dayStamp(date) {
  return date.toISOString().slice(0, 10);
}

function previousDay(date) {
  return dayStamp(new Date(date.getTime() - 24 * 60 * 60 * 1000));
}
