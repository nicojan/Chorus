# Chorus appcast feed

A Cloudflare Worker that serves the Sparkle appcast and counts how many copies of Chorus ask for it each day.

Chorus checks for updates once every 24 hours, so a count of the distinct installations that asked on a given day is a count of the people running the app that day. GitHub Pages, which served the feed before, keeps no request logs, so that number was being thrown away.

## What it does

`https://updates.nicojan.com/chorus/appcast.xml` fetches `docs/appcast.xml` from GitHub Pages and passes it through. The release steps in `release/DISTRIBUTION.md` do not change: commit the appcast, Pages republishes it, and the Worker picks it up within five minutes.

On each request it stores one key in a KV namespace. Each key hashes together the caller's address, its user-agent, the date, and a secret salt. It holds no address, and the same machine hashes to an unrelated value the next day, so the keys cannot be joined into a history of one person or turned back into an address. Each key expires after 48 hours. The version comes from the user-agent, which Sparkle sets to `Chorus/1.5.19 Sparkle/2.6.4`. Confirm that shape against the real thing after the first deploy: if it ever differs, every version reads as `unknown` and only the daily total stays right.

At 00:15 UTC a scheduled run counts yesterday's keys, writes the totals to `agg:daily`, and lets the keys expire.

Counting never blocks an update. The KV work runs after the response is on its way and swallows its own errors, so a machine whose ping goes uncounted still gets its update.

## Setting it up

You need to do this once, and only you can: it needs your Cloudflare login.

The KV namespace and both secrets already exist, so this is only for rebuilding from scratch. `wrangler.toml` carries the namespace id; a fresh `kv namespace create` prints a new one that has to replace it, or the deploy fails with `code: 10042`.

```sh
cd release/appcast-worker
npm install
npx wrangler login
npx wrangler kv namespace create PINGS   # only when starting over; paste the id into wrangler.toml
npx wrangler secret put PING_SALT        # paste: openssl rand -hex 32
npx wrangler secret put STATS_TOKEN      # paste: openssl rand -hex 24
npx wrangler deploy
```

Secrets live in Cloudflare, never in this repo. Changing `PING_SALT` later is harmless: it only makes yesterday's keys stop matching today's, so one day double-counts machines that check on both sides of the change.

Deploying creates the DNS record for `updates.nicojan.com` as well. Check it:

```sh
curl -sI https://updates.nicojan.com/chorus/appcast.xml
```

## Reading the numbers

```sh
curl -s -H "Authorization: Bearer $STATS_TOKEN" \
  https://updates.nicojan.com/chorus/stats.json
```

One record per day, newest first: the total distinct installations and a breakdown by app version. Today's record is marked `partial`, because the day is still running and it is counted live rather than read from the rollup.

A ping takes up to a minute to show up in today's `partial` record. KV listings are eventually consistent, so a check run seconds after a request will under-report and look like a bug. The rollup is unaffected: it runs at 00:15 UTC over a day that ended at 00:00.

## What the numbers mean

A day's total counts machines that checked for an update that day, which is close to but not the same as people who opened the app. A machine left running for a week checks every day, whether or not anyone touches it. A laptop that stays shut is not counted until it wakes.

Two things make the early numbers read low. Only builds from 1.5.20 on point at this feed, so every earlier copy still checks GitHub Pages and is invisible here; the count climbs as people update, and it is not growth. And several machines behind one address, or on one IPv6 network, with the same app version hash to the same key and count once.

One thing makes them read high. A machine that reaches the feed over IPv4 one day and IPv6 the next hashes to two different keys, so it counts twice. Merging the two would need something that identifies the installation across both, which is exactly the thing this deliberately does not have. Treat a day's total as accurate to within a few percent.

Reading the numbers:

```sh
curl -s -H "Authorization: Bearer $(security find-generic-password -s chorus-stats-token -w)" \
  https://updates.nicojan.com/chorus/stats.json
```

The token lives in the login Keychain. This repo is public, so it stays out of here. Cloudflare stores secrets write-only, so a lost token cannot be read back; generate a new one and upload it with `wrangler secret put STATS_TOKEN`.

## Tests

```sh
npm test
```

Covers the address normalization, which is where the counting is easiest to get quietly wrong: a rotating IPv6 address must collapse to one key, and two networks must stay two.

## Free-plan limits

Cloudflare's free tier allows 1,000 KV writes a day, and one distinct installation costs one write, so the count is honest up to about 1,000 machines a day. Past that the extra machines are silently not counted. The reads and the scheduled run are nowhere near their limits. If the total gets close to 1,000, the fix is the Workers paid plan and Analytics Engine, which has no such ceiling.
