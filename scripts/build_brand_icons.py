#!/usr/bin/env python3
"""Download brand icons from thesvg (github.com/GLINCKER/thesvg) and bundle them
as asset-catalog imagesets under Chorus/Resources/Assets.xcassets.

Monochrome marks are flagged as template assets so SwiftUI tints them .primary
and they stay visible in dark mode; colored marks render as-is. Re-run to refresh
or extend the set; pass --write to actually write the imagesets (default is a
dry-run that only prints the classification).

The logos are the trademarks of their respective owners and are bundled only to
identify each service in the sidebar. thesvg's tooling is MIT-licensed.
"""
import json, os, re, subprocess, sys

RAW = "https://raw.githubusercontent.com/GLINCKER/thesvg/main/public/icons"
ASSETS = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "Chorus", "Resources", "Assets.xcassets")
)

# catalog id -> thesvg slug (verified to exist). fastmail has no thesvg icon and
# intentionally falls back to its fetched favicon.
SLUGS = {
    "gmail":"gmail","outlook":"microsoft-outlook","protonmail":"proton-mail",
    "messenger":"messenger","slack":"slack","teams":"microsoft-teams",
    "discord":"discord","whatsapp":"whatsapp","telegram":"telegram",
    "gchat":"google-chat","linkedin":"linkedin","x":"x",
    "instagram":"instagram","facebook":"facebook","reddit":"reddit",
    "notion":"notion","trello":"trello","asana":"asana","linear":"linear",
    "gcal":"google-calendar","gdrive":"google-drive","figma":"figma",
    "github":"github","chatgpt":"openai","claude":"claude",
    "gemini":"google-gemini","perplexity":"perplexity","icloud-mail":"icloud",
    "zoom":"zoom","mattermost":"mattermost","spotify":"spotify",
    "youtube":"youtube","youtube-music":"youtube-music","twitch":"twitch",
    "google-photos":"google-photos","dropbox":"dropbox",
    "onedrive":"microsoft-onedrive","airtable":"airtable","miro":"miro",
    "canva":"canva","jira":"jira","confluence":"confluence","todoist":"todoist",
    "gitlab":"gitlab","stackoverflow":"stack-overflow",
    "hackernews":"y-combinator","substack":"substack","mistral":"mistral",
    # Added 2026-07 batch. Keys are exact catalog ids so the written imageset
    # (brand-<id>) matches ServiceIconView's lookup. Services with no thesvg
    # mark (google-meet, threads, bluesky, yahoo-mail, zoho-mail, monday,
    # element, google-voice, coda) fall back to their fetched favicon.
    "loom":"loom","tiktok":"tiktok","pinterest":"pinterest",
    "bitbucket":"bitbucket","vercel":"vercel","cloudflare":"cloudflare",
    "sentry":"sentry","clickup":"clickup","evernote":"evernote",
    "feedly":"feedly","medium":"medium","apple-music":"apple-music",
    "soundcloud":"soundcloud","replit":"replit","calendly":"calendly",
}

def fetch(slug):
    r = subprocess.run(["curl","-sf",f"{RAW}/{slug}/default.svg"],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def monochromish(r,g,b):
    if max(r,g,b)-min(r,g,b) > 24:      # chromatic
        return False
    lum = (0.2126*r+0.7152*g+0.0722*b)/255
    return lum < 0.22 or lum > 0.86     # near-black or near-white gray

def classify(svg):
    t = svg.lower()
    if re.search(r'<(linear|radial)gradient|<stop|rgb\(|hsl\(', t):
        return "color"
    named = re.findall(r'(?:fill|stroke|stop-color)="([a-z]+)"', t)
    if any(n not in ("none","currentcolor","black","white","inherit","transparent") for n in named):
        return "color"
    for h in re.findall(r'#([0-9a-f]{6}|[0-9a-f]{3})', t):
        if len(h)==3: h="".join(c*2 for c in h)
        r,g,b = int(h[0:2],16),int(h[2:4],16),int(h[4:6],16)
        if not monochromish(r,g,b):
            return "color"
    return "template"

def contents(intent):
    props = {"preserves-vector-representation": True}
    if intent == "template":
        props["template-rendering-intent"] = "template"
    return json.dumps({
        "images":[{"filename":"default.svg","idiom":"universal"}],
        "info":{"author":"xcode","version":1},
        "properties":props,
    }, indent=2)

def main():
    write = "--write" in sys.argv
    rows, missing = [], []
    for cid, slug in sorted(SLUGS.items()):
        svg = fetch(slug)
        if not svg or "<svg" not in svg:
            missing.append(cid); continue
        intent = classify(svg)
        rows.append((cid, slug, intent))
        if write:
            d = os.path.join(ASSETS, f"brand-{cid}.imageset")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d,"default.svg"),"w") as f: f.write(svg)
            with open(os.path.join(d,"Contents.json"),"w") as f: f.write(contents(intent))
    tmpl = sorted(r[0] for r in rows if r[2]=="template")
    print(f"{'WROTE' if write else 'DRY-RUN'}: {len(rows)} icons, "
          f"{len(tmpl)} template / {len(rows)-len(tmpl)} color; missing={missing}")
    print("template (tinted in dark mode):", ", ".join(tmpl))

if __name__ == "__main__":
    main()
