#!/usr/bin/env python3
"""List the extension names WebKit can show for each catalog entry.

For every entry in Chorus/Resources/ExtensionCatalog.json this downloads the
entry's `testedVersion` from its pinned source (a GitHub release asset or
addons.mozilla.org), checks the sha256 the way the app does, reads the build's
manifest name as WebKit resolves it for each locale, and prints the names that
differ from the catalog name. Those go into the entry's `alsoNamed`, so
`ExtensionCatalog.isNamed` still finds a copy a person added by hand.

Run (the -I flag is required; the script refuses to start without it):

    python3 -I scripts/catalog_extension_names.py              # JSON on stdout
    python3 -I scripts/catalog_extension_names.py --check      # compare with the catalog
    python3 -I scripts/catalog_extension_names.py --only bitwarden --check
    python3 -I scripts/catalog_extension_names.py --self-test  # offline

stdout is one JSON object, id to names, in catalog order. An empty list means
leave `alsoNamed` out. Details for each entry go to stderr.

Exit codes, in every mode:
  0  default run: every entry was read. --check: every entry matches the
     catalog. --self-test: every case passed.
  1  only when --check found a difference and nothing failed.
  2  anything else: a network or rate-limit failure, any error while reading an
     entry (an entry that failed never counts as a pass), a name that two
     entries share, an unknown --only id, a bad --dir, a missing -I, an
     unreadable catalog, or a failed --self-test.

Rerun it on every bump of a catalog `testedVersion`, then update `alsoNamed`
and set `namesReadFrom` to the new version. ChorusTests'
testNamesWereReadFromTheTestedVersion fails until you do, and
testNoNameBelongsToTwoEntries must stay green.

Downloads go to a new, empty folder outside the repo (--dir, or a temporary
one). Archives are read in memory: nothing is extracted and nothing in them
runs. Standard library only. GitHub's unauthenticated limit is 60 requests an
hour; a run uses about two per GitHub entry.
"""
import argparse
import contextlib
import fnmatch
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import warnings
import zipfile
import zlib

MAX_DOWNLOAD = 100_000_000  # the app's WebExtensionFetcher.maxDownloadBytes
MAX_UNPACKED = 500_000_000  # the app's WebExtensionLibrary.maxUnpackedBytes
MAX_MEMBERS = 20_000
READ_CAP = 5_000_000  # largest manifest.json or messages.json read
MAX_JSON = 10_000_000  # largest API answer read
TIMEOUT = 30
USER_AGENT = "chorus-catalog-names"
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DEFAULT_CATALOG = os.path.join(REPO_ROOT, "Chorus", "Resources", "ExtensionCatalog.json")

MSG_RE = re.compile(r"__MSG_([A-Za-z0-9_@]+)__")
NAMED_RE = re.compile(r"(?:[^$]|^)(\$([A-Za-z0-9_@]+)\$)")
POSITIONAL_RE = re.compile(r"(?:[^$]|^)(\$([0-9]))")
FOLDER_RE = re.compile(r"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,4})?$")
LOOP_LIMIT = 10_000


class Failure(Exception):
    """One entry cannot be read. The run reports it and moves on."""


class RateLimited(Exception):
    """GitHub refused the request. The run stops."""


# ---------------------------------------------------------------- text helpers

def swift_trim(text):
    """Trim what Swift's whitespacesAndNewlines trims (not str.strip)."""
    def trims(ch):
        return ch in "\t\n\v\f\r\x85" or unicodedata.category(ch) in ("Zs", "Zl", "Zp")
    start, end = 0, len(text)
    while start < end and trims(text[start]):
        start += 1
    while end > start and trims(text[end - 1]):
        end -= 1
    return text[start:end]


_ASCII_LOWER = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}


def ascii_lower(text):
    """Lowercase A-Z only, as WebKit's convertToASCIILowercase does (not str.lower)."""
    return text.translate(_ASCII_LOWER)


def is_plain_name(name):
    """Port of WebExtensionSource.isPlainName."""
    return re.fullmatch(r"[A-Za-z0-9._-]+", name) is not None and name not in (".", "..")


def name_key(text):
    return swift_trim(text).lower()


def parse_version(text):
    """The app's WebExtensionVersion: 1 to 6 dotted pieces of 1 to 9 digits."""
    pieces = text.split(".")
    if not 1 <= len(pieces) <= 6 or not all(re.fullmatch(r"[0-9]{1,9}", p) for p in pieces):
        return None
    numbers = [int(p) for p in pieces]
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers.pop()
    return tuple(numbers)


def same_version(a, b):
    left = parse_version(a)
    return left is not None and left == parse_version(b)


def parse_sha256(value):
    """The hex digest in "sha256:<64 hex>", or None."""
    if not isinstance(value, str) or not value.lower().startswith("sha256:"):
        return None
    hex_part = value[len("sha256:"):].lower()
    return hex_part if re.fullmatch(r"[0-9a-f]{64}", hex_part) else None


def decode_text(data):
    """Strict decoding. Raises UnicodeDecodeError (a ValueError) on bad bytes."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8")
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16")
    return data.decode("utf-8")


def json_escape(text):
    """json.dumps without ASCII escaping, but with Cc, Cf, Zl and Zp escaped."""
    out = []
    for ch in json.dumps(text, ensure_ascii=False):
        if unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp"):
            code = ord(ch)
            if code > 0xFFFF:
                code -= 0x10000
                out.append("\\u%04x\\u%04x" % (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF)))
            else:
                out.append("\\u%04x" % code)
        else:
            out.append(ch)
    return "".join(out)


# ----------------------------------------------------------------- URL checks

def publishes(kind, ident, url, tag=None, asset=None):
    """Port of WebExtensionSource.publishes, plus the tag and asset match."""
    parts = urllib.parse.urlsplit(url)
    try:
        port = parts.port
    except ValueError:
        return False
    if (parts.scheme != "https" or parts.username or parts.password or port is not None
            or parts.query or parts.fragment or "?" in url or "#" in url or "@" in parts.netloc):
        return False
    low = parts.path.lower()
    if "%2f" in low or "%2e" in low or "%5c" in low:
        return False
    segments = [urllib.parse.unquote(s) for s in parts.path.split("/")[1:]]
    if any(s in ("", ".", "..") for s in segments):
        return False
    comps = ["/"] + segments
    host = (parts.hostname or "").lower()
    if kind == "github":
        owner, repo, pattern = ident
        return (host == "github.com" and len(comps) == 7
                and comps[1].lower() == owner.lower() and comps[2].lower() == repo.lower()
                and comps[3] == "releases" and comps[4] == "download"
                and fnmatch.fnmatchcase(comps[6], pattern)
                and (tag is None or comps[5] == tag) and (asset is None or comps[6] == asset))
    return (host == "addons.mozilla.org" and len(comps) == 6
            and comps[1:4] == ["firefox", "downloads", "file"]
            and re.fullmatch(r"[0-9]+", comps[4]) is not None
            and comps[5].lower().endswith(".xpi"))


# ----------------------------------------------------------------------- HTTP

class _HttpsOnly(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise Failure("redirect to a non-https address")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_HttpsOnly)


def _request(url, github=False):
    headers = {"User-Agent": USER_AGENT}
    if github:
        headers["Accept"] = "application/vnd.github+json"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    return urllib.request.Request(url, headers=headers)


def _limited(err):
    return err.code == 429 or (err.code == 403 and err.headers.get("x-ratelimit-remaining") == "0")


def _reset_text(err):
    reset = err.headers.get("x-ratelimit-reset")
    if reset and reset.isdigit():
        import time
        return " (resets at %s)" % time.strftime("%H:%M:%S", time.localtime(int(reset)))
    return ""


def get_json(url, github=False):
    """(status, parsed) for a 200, or (404, None). Anything else raises."""
    try:
        with _OPENER.open(_request(url, github), timeout=TIMEOUT) as resp:
            data = resp.read(MAX_JSON + 1)
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return 404, None
        if _limited(err):
            raise RateLimited("rate limited by %s%s" % (urllib.parse.urlsplit(url).hostname, _reset_text(err)))
        raise Failure("HTTP %d from %s" % (err.code, url))
    except (urllib.error.URLError, OSError) as err:
        raise Failure("cannot reach %s: %s" % (url, err))
    if len(data) > MAX_JSON:
        raise Failure("answer from %s is too large" % url)
    try:
        return 200, json.loads(data)
    except ValueError:
        raise Failure("answer from %s is not JSON" % url)


def check_rate_limit(github_entries):
    status, body = get_json("https://api.github.com/rate_limit", github=True)
    try:
        remaining = body["resources"]["core"]["remaining"]
    except (TypeError, KeyError):
        raise Failure("cannot read GitHub's rate limit")
    if remaining < 3 * github_entries:
        raise RateLimited("GitHub has %d requests left, %d needed" % (remaining, 3 * github_entries))


def download(url, size, hex_digest, path):
    """Stream `url` to a new file at `path`. Size and sha256 must both match."""
    if not isinstance(size, int) or size <= 0 or size > MAX_DOWNLOAD:
        raise Failure("reported size %r is missing or over %d" % (size, MAX_DOWNLOAD))
    digest, total = hashlib.sha256(), 0
    try:
        with _OPENER.open(_request(url), timeout=TIMEOUT) as resp, open(path, "xb") as out:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_DOWNLOAD:
                    raise Failure("download passed %d bytes" % MAX_DOWNLOAD)
                digest.update(chunk)
                out.write(chunk)
    except urllib.error.HTTPError as err:
        if _limited(err):
            raise RateLimited("rate limited by %s%s" % (urllib.parse.urlsplit(url).hostname, _reset_text(err)))
        raise Failure("HTTP %d from %s" % (err.code, url))
    except (urllib.error.URLError, OSError) as err:
        raise Failure("download failed: %s" % err)
    if total != size:
        raise Failure("got %d bytes, expected %d" % (total, size))
    if digest.hexdigest() != hex_digest:
        raise Failure("sha256 mismatch")
    return total


# -------------------------------------------------------------- finding a release

def _release_dict(url, version_text, tested, digest, size, source):
    if not same_version(version_text, tested):
        raise Failure("release is %s, not %s" % (version_text, tested))
    hex_digest = parse_sha256(digest)
    if hex_digest is None:
        raise Failure("no usable sha256 digest")
    return {"url": url, "sha256": hex_digest, "size": size, "source": source}


def find_github(src, tested):
    owner, repo, pattern = src["owner"], src["repo"], src["assetPattern"]
    prefix = src.get("tagPrefix") or ""
    base = "https://api.github.com/repos/%s/%s/releases/tags/" % (owner, repo)
    tried, found = [], []
    for spelling in ("", "v", "V"):
        if spelling == "V" and found:
            break
        tag = prefix + spelling + tested
        tried.append(tag)
        status, body = get_json(base + urllib.parse.quote(tag, safe=""), github=True)
        if status == 200:
            found.append(body)
        if spelling == "v" and len(found) == 2:
            raise Failure("ambiguous tags: %s" % ", ".join(tried))
    if not found:
        raise Failure("version %s gone; tried tags %s" % (tested, ", ".join(tried)))
    rel = found[0]
    tag = rel.get("tag_name")
    if rel.get("draft") or rel.get("prerelease"):
        raise Failure("release %s is a draft or prerelease" % tag)
    if not isinstance(tag, str) or not tag.startswith(prefix):
        raise Failure("unexpected tag %r" % (tag,))
    rest = tag[len(prefix):]
    text = rest[1:] if rest[:1] in ("v", "V") else rest
    matches = [a for a in rel.get("assets") or [] if fnmatch.fnmatchcase(a.get("name", ""), pattern)]
    if len(matches) != 1:
        raise Failure("%d assets match %s in %s" % (len(matches), pattern, tag))
    asset = matches[0]
    if not publishes("github", (owner, repo, pattern), asset.get("browser_download_url", ""), tag, asset["name"]):
        raise Failure("untrusted download address %s" % asset.get("browser_download_url"))
    found_release = _release_dict(asset["browser_download_url"], text, tested,
                                  asset.get("digest"), asset.get("size"), "GitHub tag " + tag)
    found_release["ext"] = "zip"
    return found_release


def find_amo(src, tested):
    slug = src["slug"]
    url = "https://addons.mozilla.org/api/v5/addons/addon/%s/versions/%s/" % (slug, urllib.parse.quote(tested, safe=""))
    status, body = get_json(url)
    if status == 404:
        raise Failure("version %s gone from AMO" % tested)
    if not isinstance(body, dict) or not isinstance(body.get("file"), dict):
        raise Failure("unreadable AMO answer")
    file_info = body["file"]
    if body.get("version") != tested:
        raise Failure("AMO answered version %r" % body.get("version"))
    if file_info.get("status") != "public":
        raise Failure("AMO file status is %r" % file_info.get("status"))
    if not publishes("amo", None, file_info.get("url", "")):
        raise Failure("untrusted download address %s" % file_info.get("url"))
    found_release = _release_dict(file_info["url"], body["version"], tested,
                                  file_info.get("hash"), file_info.get("size"), "AMO " + slug)
    found_release["ext"] = "xpi"
    if body.get("channel") != "listed":
        found_release["warning"] = "channel is %r, not listed" % body.get("channel")
    return found_release


# ------------------------------------------------------------------- the archive

def check_infos(infos):
    """Refuse an archive the app would not unpack safely."""
    if len(infos) > MAX_MEMBERS:
        raise Failure("archive has %d members" % len(infos))
    if sum(i.file_size for i in infos) > MAX_UNPACKED:
        raise Failure("archive unpacks to over %d bytes" % MAX_UNPACKED)
    seen = set()
    for info in infos:
        name = info.filename
        segments = name.rstrip("/").split("/")
        if (not name or name[0] in "/\\" or "\\" in name or "\0" in name
                or re.match(r"^[A-Za-z]:", name) or any(s in (".", "..") for s in segments)):
            raise Failure("unsafe member name %r" % name)
        if info.flag_bits & 1 or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise Failure("encrypted or unusual compression: %r" % name)
        if (info.external_attr >> 16) & 0o170000 == 0o120000:
            raise Failure("symlink in archive: %r" % name)
        if name.lower() in seen:
            raise Failure("duplicate member name %r" % name)
        seen.add(name.lower())


class Archive:
    """A zip read in memory, with case-insensitive lookup like APFS."""

    def __init__(self, source):
        try:
            self.zf = zipfile.ZipFile(source)
        except (zipfile.BadZipFile, OSError) as err:
            raise Failure("not a readable zip: %s" % err)
        self.infos = self.zf.infolist()
        check_infos(self.infos)
        self.members = {i.filename.lower(): i for i in self.infos}
        self.root = self._find_root()

    def _find_root(self):
        if "manifest.json" in self.members:
            return ""
        folders = {i.filename.split("/")[0] for i in self.infos if "/" in i.filename}
        folders = {f for f in folders if f != "__MACOSX" and not f.startswith(".")}
        if len(folders) == 1:
            only = next(iter(folders)) + "/"
            if (only + "manifest.json").lower() in self.members:
                return only
        raise Failure("no manifest.json at the top or in a single folder")

    def read(self, relative):
        info = self.members.get((self.root + relative).lower())
        if info is None:
            return None
        with self.zf.open(info) as handle:
            data = handle.read(READ_CAP + 1)
        if len(data) > READ_CAP:
            raise Failure("%s is over %d bytes" % (relative, READ_CAP))
        return data

    def locale_folders(self):
        prefix = self.root + "_locales/"
        found = set()
        for info in self.infos:
            if info.filename[:len(prefix)].lower() == prefix.lower():
                parts = info.filename[len(prefix):].split("/")
                if len(parts) > 1 and parts[0]:
                    found.add(parts[0])
        return sorted(found)


# ----------------------------------------------------------- reading JSON files

def _no_constant(name):
    raise ValueError("%s is not JSON" % name)


def strip_trailing_commas(text):
    """Drop a comma before } or ], leaving strings alone (WebKit allows these in manifest.json)."""
    out, in_string, escaped = [], False, False
    for index, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == ",":
            rest = text[index + 1:].lstrip(" \t\r\n")
            if rest[:1] in ("}", "]"):
                continue
        out.append(ch)
    return "".join(out)


def load_manifest(archive, tested):
    data = archive.read("manifest.json")
    if data is None:
        raise Failure("manifest.json missing")
    try:
        manifest = json.loads(strip_trailing_commas(decode_text(data)), parse_constant=_no_constant)
    except ValueError as err:
        raise Failure("manifest.json is not JSON: %s" % err)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("name"), str):
        raise Failure("manifest has no string name")
    if not same_version(str(manifest.get("version")), tested):
        raise Failure("manifest version is %r, not %s" % (manifest.get("version"), tested))
    return manifest


def load_messages(archive, locale, is_default, warnings_out):
    """The locale's messages with lowercased keys, or None when WebKit would treat it as missing."""
    data = archive.read("_locales/%s/messages.json" % locale)
    if data is None:
        return None
    dupes = []

    def hook(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                dupes.append(key)
            result[key] = value
        return result

    try:
        parsed = json.loads(decode_text(data), object_pairs_hook=hook, parse_constant=_no_constant)
    except ValueError as err:
        if is_default:
            raise Failure("default locale %s: messages.json is not strict JSON: %s" % (locale, err))
        warnings_out.append("%s: messages.json is not strict JSON, WebKit skips it (%s)" % (locale, err))
        return None
    if not isinstance(parsed, dict):
        warnings_out.append("%s: messages.json is not an object" % locale)
        return None
    if dupes:
        warnings_out.append("%s: duplicate keys %s" % (locale, sorted(set(dupes))[:5]))
    lowered = {}
    for key, value in parsed.items():
        if ascii_lower(key) in lowered and lowered[ascii_lower(key)] != value:
            raise Failure("%s: keys differing only by case, %r, carry different messages" % (locale, key))
        lowered[ascii_lower(key)] = value
    return lowered


# --------------------------------------------------------- WebKit's resolution

def _replace_loop(text, regex, replacement_for, advance):
    """Port of WebKit's replace-all-then-continue loops."""
    index = steps = 0
    while index < len(text):
        steps += 1
        match = regex.search(text, index)
        if match is None or steps > LOOP_LIMIT:
            if steps > LOOP_LIMIT:
                raise Failure("placeholder replacement does not end")
            break
        original = match.group(1)
        replacement = replacement_for(match)
        text = text.replace(original, replacement)
        index = match.start() + advance(replacement)
        if not match.group(0):
            break
    return text


def apply_placeholders(message, placeholders):
    named = {}
    if isinstance(placeholders, dict):
        named = {ascii_lower(k): v for k, v in placeholders.items()}

    def content(match):
        entry = named.get(ascii_lower(match.group(2)))
        value = entry.get("content") if isinstance(entry, dict) else None
        return value if isinstance(value, str) else ""

    message = _replace_loop(message, NAMED_RE, content, lambda r: max(0, len(r) - 1))
    message = _replace_loop(message, POSITIONAL_RE, lambda m: "", lambda r: 0)
    return message.replace("$$", "$")


def localize(text, table):
    """Port of WebExtensionLocalization::localizedStringForString."""
    index = steps = 0
    while index < len(text):
        steps += 1
        match = MSG_RE.search(text, index)
        if match is None:
            break
        if steps > LOOP_LIMIT:
            raise Failure("localization does not end")
        key = match.group(1)
        if key.startswith("@@"):
            raise Failure("name uses the predefined message %s, which this script does not resolve" % key)
        entry = table.get(ascii_lower(key))
        message = entry.get("message") if isinstance(entry, dict) else None
        replacement = ""
        if isinstance(message, str) and message:
            replacement = apply_placeholders(message, entry.get("placeholders"))
        text = text.replace(match.group(0), replacement)
        index = match.start() + len(replacement)
    return text


def build_table(archive, manifest, best, cache, warnings_out):
    """The merged messages WebKit uses when `best` is the best-matching locale."""
    default = manifest.get("default_locale")
    if not isinstance(default, str) or not default:
        return {}

    def messages(locale):
        if locale not in cache:
            cache[locale] = load_messages(archive, locale, locale == default, warnings_out)
        return cache[locale]

    if messages(default) is None:
        return {}
    language = re.split(r"[_-]", best)[0]
    layers = []
    if best != language and best != default:
        layers.append(messages(best))
    if language and language != default:
        layers.append(messages(language))
    layers.append(messages(default))
    table = {}
    for layer in layers:
        for key, value in (layer or {}).items():
            table.setdefault(key, value)
    return table


def harvest(archive, entry_name, tested):
    """(names that differ from the catalog name, info lines, warnings) for one build."""
    warns = []
    manifest = load_manifest(archive, tested)
    default = manifest.get("default_locale")
    default = default if isinstance(default, str) else ""
    folders = archive.locale_folders()
    for folder in folders:
        if not FOLDER_RE.match(folder) or len(re.split(r"[_-]", folder)) > 2:
            warns.append("unusual locale folder name %r" % folder)
    if "__MSG_" in manifest["name"] and not default:
        warns.append("name has a token but no default_locale; WebKit shows no name")
    candidates = ([default] if default else [""]) + [f for f in folders if f != default]
    seen, names, cache, uses_catalog = {name_key(entry_name)}, [], {}, False
    for best in candidates:
        table = build_table(archive, manifest, best, cache, warns)
        resolved = swift_trim(localize(manifest["name"], table))
        uses_catalog = uses_catalog or name_key(resolved) == name_key(entry_name)
        if not resolved:
            warns.append("name is empty for locale %r; dropped" % best)
        elif resolved.lower() not in seen:
            seen.add(resolved.lower())
            names.append(resolved)
    info = ["manifest version %s" % manifest.get("version"),
            "default_locale %r, %d locale folders, %d names" % (default, len(folders), len(names)),
            "catalog name %s the build" % ("used by" if uses_catalog else "not used by")]
    return names, info, sorted(set(warns))


# ------------------------------------------------------------------- the run

def check_names(entry_id, tested, source):
    """Refuse an id, version, owner, repo or slug the app's own checks would refuse."""
    if not is_plain_name(entry_id) or parse_version(tested) is None:
        raise Failure("bad id or testedVersion")
    if "github" in source:
        if not all(is_plain_name(source["github"][k]) for k in ("owner", "repo")):
            raise Failure("bad owner or repo")
    elif not is_plain_name(source["amo"]["slug"]) or "." in source["amo"]["slug"]:
        raise Failure("bad slug")


def process(entry, workdir):
    """Download, verify and read one entry. Returns (names, info lines, warnings)."""
    tested, source = entry["testedVersion"], entry["source"]
    check_names(entry["id"], tested, source)
    release = find_github(source["github"], tested) if "github" in source else find_amo(source["amo"], tested)
    path = os.path.join(workdir, "%s-%s.%s" % (entry["id"], tested, release["ext"]))
    total = download(release["url"], release["size"], release["sha256"], path)
    info = [release["source"], release["url"], "%d bytes, sha256 ok" % total]
    names, more, warns = harvest(Archive(path), entry["name"], tested)
    if release.get("warning"):
        warns.append(release["warning"])
    return names, info + more, warns


def cross_check(results, catalog_names):
    """Exit-2 collisions: a name owned by two entries (testNoNameBelongsToTwoEntries)."""
    owner, problems = {}, []
    for entry_id, names in results.items():
        for key in {name_key(n) for n in [catalog_names[entry_id]] + names}:
            if key in owner:
                problems.append("%r belongs to both %s and %s" % (key, owner[key], entry_id))
            owner[key] = entry_id
    return problems


def compare(entry, names):
    """Lines describing how the committed alsoNamed differs from the build."""
    committed = {name_key(n) for n in entry.get("alsoNamed") or []}
    built = {name_key(n) for n in names}
    lines = ["missing from JSON: %s" % n for n in names if name_key(n) not in committed]
    lines += ["in JSON but not in build: %s" % n for n in entry.get("alsoNamed") or []
              if name_key(n) not in built and name_key(n) != name_key(entry["name"])]
    lines += ["redundant in JSON (same as catalog name): %s" % n for n in entry.get("alsoNamed") or []
              if name_key(n) == name_key(entry["name"])]
    return lines


def die(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def inside(path, root):
    """Whether `path` is `root` or under it, even when the volume ignores case."""
    target = os.path.realpath(path)
    root_stat = os.stat(root)
    probe = target
    while True:
        try:
            found = os.stat(probe)
        except OSError:
            found = None
        if found and (found.st_dev, found.st_ino) == (root_stat.st_dev, root_stat.st_ino):
            return True
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent

    def fold(value):
        return os.path.normcase(value).casefold()
    return fold(target) == fold(root) or fold(target).startswith(fold(root) + os.sep)


def prepare_dir(requested):
    """(folder, created_here). The folder is new or empty, and outside the repo."""
    if requested is None:
        return tempfile.mkdtemp(prefix="chorus-catalog-names-"), True
    real = os.path.realpath(requested)
    if inside(real, REPO_ROOT):
        die("--dir must be outside the repo")
    if os.path.exists(real) and (not os.path.isdir(real) or os.listdir(real)):
        die("--dir must be absent or empty")
    os.makedirs(real, exist_ok=True)
    return real, False


def say(*lines):
    print("\n".join(lines), file=sys.stderr)


def load_entries(args):
    try:
        with open(args.catalog, encoding="utf-8") as handle:
            entries = json.load(handle)
        ids = {e["id"] for e in entries}
    except (OSError, ValueError, KeyError, TypeError) as err:
        die("cannot read the catalog: %s" % err)
    unknown = set(args.only or []) - ids
    if unknown:
        die("unknown id: %s" % ", ".join(sorted(unknown)))
    return [e for e in entries if not args.only or e["id"] in args.only]


def read_entry(entry, workdir):
    """(names, info lines, warnings), or None after printing why it failed."""
    try:
        return process(entry, workdir)
    except RateLimited:
        raise
    except Failure as err:
        say("  FAILED: %s" % err)
    except Exception as err:  # odd archives and odd API answers must not stop the run
        say("  FAILED: unexpected %s: %s" % (type(err).__name__, err))
    return None


def run(args):
    entries = load_entries(args)
    workdir, temporary = prepare_dir(args.dir)
    results, failed, differs = {}, False, False
    try:
        github_count = sum(1 for e in entries if "github" in e["source"])
        if github_count:
            check_rate_limit(github_count)
        for entry in entries:
            say("== %s" % entry["id"])
            read = read_entry(entry, workdir)
            if read is None:
                failed = True
                continue
            names, info, warns = read
            say(*["  " + line for line in info + ["warning: " + w for w in warns]])
            results[entry["id"]] = names
            if args.check:
                diff = compare(entry, names)
                print("%s: %s" % (entry["id"], "matches the catalog" if not diff else "DIFFERS"))
                print("\n".join("  " + line for line in diff), end="\n" if diff else "")
                differs = differs or bool(diff)
    except (RateLimited, Failure) as err:
        say("STOPPED: %s" % err)
        failed = True
    finally:
        if temporary and not (args.keep or failed):
            shutil.rmtree(workdir, ignore_errors=True)
        else:
            say("downloads kept in %s" % workdir)
    problems = cross_check(results, {e["id"]: e["name"] for e in entries})
    say(*["COLLISION: " + p for p in problems])
    if not args.check:
        body = ",\n".join(" %s: [%s]" % (json.dumps(i), ", ".join(json_escape(n) for n in ns))
                          for i, ns in results.items())
        print("{\n%s\n}" % body)
    return 2 if failed or problems else 1 if differs else 0


# ------------------------------------------------------------------ self test

def _zip(files, root=""):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in files.items():
            zf.writestr(root + name, data if isinstance(data, bytes) else json.dumps(data))
    return Archive(buffer)


def _msg(text, **kw):
    return {"message": text, **kw}


def _names(files, catalog="Cat", root=""):
    return harvest(_zip(files, root), catalog, "1.0")


def _manifest(name, locale="en", **kw):
    base = {"name": name, "version": "1.0.0"}
    if locale:
        base["default_locale"] = locale
    return {"manifest.json": {**base, **kw}}


def _expect_failure(label, build):
    """True when `build` raises Failure."""
    try:
        build()
    except Failure:
        return True
    return False


def _resolver_cases():
    nm = "__MSG_name__"
    base = _manifest(nm)
    en = {"_locales/en/messages.json": {"NAME": _msg("Foo")}}
    pt = {"_locales/pt/messages.json": {"name": _msg("Pt")}}
    br = {"_locales/pt_BR/messages.json": {"name": _msg("PtBR")}}
    return [
        ("keys ignore case", _names({**base, **en})[0] == ["Foo"]),
        ("pt_BR over pt over en", _names({**base, **en, **pt, **br})[0] == ["Foo", "Pt", "PtBR"]),
        ("pt_BR falls back to pt", _names({**base, **en, **pt, "_locales/pt_BR/messages.json": {"x": _msg("y")}})[0] == ["Foo", "Pt"]),
        ("missing key leaves a gap", _names({**_manifest("Foo __MSG_x__"), "_locales/en/messages.json": {"y": _msg("1")}})[0] == ["Foo"]),
        ("no default_locale drops the name", _names(_manifest(nm, locale=None))[0] == [] and bool(_names(_manifest(nm, locale=None))[2])),
        ("manifest trailing comma", _names({"manifest.json": b'{"name":"A, B","version":"1.0",}'})[0] == ["A, B"]),
        ("messages trailing comma is missing", _names({**base, **en, "_locales/pt/messages.json": b'{"name":{"message":"Pt"},}'})[0] == ["Foo"]),
        ("utf-8 BOM", _names({"manifest.json": b'\xef\xbb\xbf{"name":"Bom","version":"1.0"}'})[0] == ["Bom"]),
        ("utf-16 BOM", _names({**base, "_locales/en/messages.json": '{"name":{"message":"Wide"}}'.encode("utf-16")})[0] == ["Wide"]),
        ("named placeholder", _names({**_manifest("__MSG_n__"), "_locales/en/messages.json": {"n": _msg("$P$ Pass", placeholders={"P": {"content": "Bit"}})}})[0] == ["Bit Pass"]),
        ("$1 removed, $$ kept as $", _names({**_manifest("__MSG_n__"), "_locales/en/messages.json": {"n": _msg("A$1 B$$C")}})[0] == ["A B$C"]),
        ("repeated token", _names({**_manifest("__MSG_a__ __MSG_a__"), "_locales/en/messages.json": {"a": _msg("X")}})[0] == ["X X"]),
        ("catalog name dropped, case ignored", _names({**base, **en}, catalog=" foo ")[0] == []),
        ("comments in default file", _expect_failure("comments", lambda: _names({**base, "_locales/en/messages.json": b'// c\n{"name":{"message":"A"}}'}))),
        ("@@ in a name", _expect_failure("@@", lambda: _names({**_manifest("__MSG_@@ui_locale__"), **en}))),
        ("case-duplicate keys", _expect_failure("dup", lambda: _names({**base, "_locales/en/messages.json": b'{"a":{"message":"1"},"A":{"message":"2"}}'}))),
        ("_locales/EN found for default en", _names({**base, "_locales/EN/messages.json": {"name": _msg("Up")}})[0] == ["Up"]),
        ("__MACOSX beside one folder", _names({**base, **en, "__MACOSX/x": b"z"}, root="") [0] == ["Foo"]
         and _names({"__MACOSX/x": b"z", **{"top/" + k: v for k, v in {**base, **en}.items()}})[0] == ["Foo"]),
    ]


def _archive_cases():
    def info(name, size=1, attr=0):
        item = zipfile.ZipInfo(name)
        item.file_size, item.external_attr = size, attr
        return item
    bad_names = ["../x", "/abs", "a\\b", "a/../b", "C:x"]
    link = zipfile.ZipInfo("link")
    link.external_attr = 0o120777 << 16
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf, warnings.catch_warnings():
        warnings.simplefilter("ignore")
        zf.writestr("A.txt", "1")
        zf.writestr("a.txt", "2")
    big = io.BytesIO()
    with zipfile.ZipFile(big, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", b" " * (READ_CAP + 1))
    cases = [("rejects " + n, _expect_failure(n, lambda n=n: check_infos([info(n)]))) for n in bad_names]
    cases += [
        ("rejects symlink", _expect_failure("link", lambda: check_infos([link]))),
        ("rejects case-duplicate names", _expect_failure("dup", lambda: Archive(buffer))),
        ("rejects a lying total", _expect_failure("total", lambda: check_infos([info("a", 300_000_000), info("b", 300_000_000)]))),
        ("read cap", _expect_failure("cap", lambda: Archive(big).read("manifest.json"))),
    ]
    return cases


def _table_cases():
    gh = ("Owner", "Repo", "asset-*.zip")
    good = "https://github.com/owner/repo/releases/download/v1/asset-1.zip"
    amo = "https://addons.mozilla.org/firefox/downloads/file/123/x-1.xpi"
    bad_gh = ["http://github.com/owner/repo/releases/download/v1/asset-1.zip",
              good + "?a=1", good.replace("github.com", "github.com:8443"),
              good.replace("v1", "v%2f1"), good.replace("v1", ".."),
              good.replace("repo", "other"), good.replace("asset-1.zip", "x.zip"),
              "https://github.com/owner/repo/releases/download/asset-1.zip",
              "https://evil.com/owner/repo/releases/download/v1/asset-1.zip"]
    bad_amo = [amo.replace("https", "http"), amo.replace("123", "12a"), amo.replace(".xpi", ".zip"),
               amo.replace("firefox", "android"), amo + "#x"]
    hexa = "a" * 64
    return [
        ("github url ok", publishes("github", gh, good, "v1", "asset-1.zip")),
        ("github url tag mismatch", not publishes("github", gh, good, "v2")),
        ("amo url ok", publishes("amo", None, amo)),
        ("bad github urls", not any(publishes("github", gh, u) for u in bad_gh)),
        ("bad amo urls", not any(publishes("amo", None, u) for u in bad_amo)),
        ("sha256 good", parse_sha256("sha256:" + hexa) == hexa and parse_sha256("SHA256:" + hexa.upper()) == hexa),
        ("sha256 bad", not any(parse_sha256(v) for v in (hexa, "sha256:" + "a" * 63, "sha256:" + "g" * 64, None, ""))),
        ("version padding", same_version("3.1", "3.1.0") and not same_version("3.1", "3.1.1") and parse_version("1.2.3.4.5.6.7") is None),
        ("swift trim", swift_trim("  x \x85") == "x"),
    ]


def _quiet(call):
    """The result of call(), or the SystemExit code, with stdout and stderr muted."""
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        try:
            return call()
        except SystemExit as err:
            return err.code


def _exit_code(entries, patches=None, only=None, check=False, folder=None):
    """What run() returns for a catalog of `entries`, with module functions swapped for fakes."""
    with tempfile.TemporaryDirectory() as tmp:
        catalog = os.path.join(tmp, "catalog.json")
        with open(catalog, "w", encoding="utf-8") as handle:
            json.dump(entries, handle)
        args = argparse.Namespace(catalog=catalog, dir=folder, only=only, check=check, keep=False)
        saved = {key: globals()[key] for key in (patches or {})}
        globals().update(patches or {})
        try:
            return _quiet(lambda: run(args))
        finally:
            globals().update(saved)


def _raises(error):
    def fake(*_args):
        raise error
    return fake


def _entry(also=None, github=False):
    source = {"github": {"owner": "o", "repo": "r", "assetPattern": "*.zip"}} if github else {"amo": {"slug": "x"}}
    return {"id": "x", "name": "X", "testedVersion": "1.0", "source": source, **({"alsoNamed": also} if also else {})}


def _exit_cases():
    odd = [zipfile.BadZipFile("x"), zlib.error("x"), KeyError("k"), AttributeError("a")]
    cases = [("exit 2 on %s in process()" % type(e).__name__,
              _exit_code([_entry()], {"process": _raises(e)}) == 2) for e in odd]
    found = lambda *_a: (["Alt"], [], [])
    return cases + [
        ("exit 2 when the rate-limit check fails", _exit_code([_entry(github=True)], {"check_rate_limit": _raises(Failure("x"))}) == 2),
        ("exit 2 on an unknown --only id", _exit_code([_entry()], only=["nope"]) == 2),
        ("exit 2 on a --dir inside the repo", _exit_code([_entry()], folder=os.path.join(REPO_ROOT, "zz-new")) == 2),
        ("exit 2 when --check meets a failed entry", _exit_code([_entry()], {"process": _raises(KeyError("k"))}, check=True) == 2),
        ("exit 0 on a clean run", _exit_code([_entry()], {"process": found}) == 0),
        ("exit 0 when --check matches", _exit_code([_entry(["Alt"])], {"process": found}, check=True) == 0),
        ("exit 1 only for a --check difference", _exit_code([_entry()], {"process": found}, check=True) == 1),
        ("exit 2 when the self-test fails", _quiet(lambda: _report([("bad", False)])) == 2),
    ]


def _comma_cases():
    def strip(text):
        try:
            return json.loads(strip_trailing_commas(text))
        except ValueError:
            return None
    return [
        ("comma after one escaped quote", strip('{"a":"q\\"","b":1,}') == {"a": 'q"', "b": 1}),
        ("comma after two escaped quotes", strip('{"a":"q\\"\\"","b":1,}') == {"a": 'q""', "b": 1}),
        ("comma after an escaped backslash", strip('{"a":"q\\\\","b":1,}') == {"a": "q\\", "b": 1}),
        (", ] inside a later string is kept", strip('{"a":"x\\"y","b":", ]",}') == {"a": 'x"y', "b": ", ]"}),
        ("trailing comma in an array", strip('{"a":[1,2,],}') == {"a": [1, 2]}),
    ]


def _elsewhere_ok(files, bad_bytes):
    names, _info, warns = _names({**files, "_locales/pt/messages.json": bad_bytes})
    return names == ["Foo"] and any(w.startswith("pt:") for w in warns)


def _fix_cases():
    github = {"github": {"owner": "o", "repo": "r"}}
    def bad(source, entry_id="x"):
        return _expect_failure("names", lambda: check_names(entry_id, "1.0", source))
    kelvin = {**_manifest("Pre __MSG_k__"), "_locales/en/messages.json": {"\u212a": _msg("Bad")}}
    bad_utf8 = b'{"name":{"message":"A\xff"}}'
    plain_en = {**_manifest("__MSG_name__"), "_locales/en/messages.json": {"name": _msg("Foo")}}
    caps = {"A": _msg("1")}
    return [
        ("plain names: dots and ..", bad({"github": {**github["github"], "owner": ".."}})
         and bad({"github": {**github["github"], "repo": "."}}) and bad({"amo": {"slug": "a.b"}})
         and bad(github, "..") and bad({"amo": {"slug": "bad/slug"}})),
        ("plain names: ordinary ones pass", _quiet(lambda: check_names("a-b_c", "1.0", {"amo": {"slug": "a-b_c"}})) is None
         and _quiet(lambda: check_names("a", "1.0", {"github": {"owner": "a.b", "repo": "c_d"}})) is None),
        ("inside() sees a differently-cased repo path", inside(REPO_ROOT.swapcase(), REPO_ROOT)
         and inside(os.path.join(REPO_ROOT.swapcase(), "zz", "new"), REPO_ROOT)),
        ("inside() sees a folder in the repo", inside(os.path.join(REPO_ROOT, "scripts", "zz"), REPO_ROOT)),
        ("inside() lets another folder through", not inside(tempfile.gettempdir(), REPO_ROOT)),
        ("prepare_dir refuses a differently-cased repo path",
         _quiet(lambda: prepare_dir(os.path.join(REPO_ROOT.swapcase(), "zz-new"))) == 2),
        ("invalid UTF-8 in manifest.json fails", _expect_failure("utf8", lambda: _names({"manifest.json": b'{"name":"A\xff","version":"1.0"}'}))),
        ("invalid UTF-8 in the default messages.json fails",
         _expect_failure("utf8", lambda: _names({**_manifest("__MSG_name__"), "_locales/en/messages.json": bad_utf8}))),
        ("invalid UTF-8 elsewhere warns, never U+FFFD", _elsewhere_ok(plain_en, bad_utf8)),
        ("KELVIN SIGN key does not match k", _names(kelvin)[0] == ["Pre"]),
        ("ASCII keys still ignore case", _names({**_manifest("__MSG_a__"), "_locales/en/messages.json": caps})[0] == ["1"]),
        ("reports a catalog name the build does not use", "catalog name not used by the build" in _names(plain_en, catalog="Cat")[1]),
        ("reports a catalog name the build uses", "catalog name used by the build" in _names(plain_en, catalog="Foo")[1]),
    ]


def _report(cases):
    failures = []
    for label, ok in cases:
        print("%s %s" % ("ok  " if ok else "FAIL", label), file=sys.stderr)
        if not ok:
            failures.append(label)
    print("self-test: %s" % ("passed" if not failures else "FAILED: " + "; ".join(failures)))
    return 2 if failures else 0


def self_test():
    return _report(_resolver_cases() + _archive_cases() + _table_cases()
                   + _comma_cases() + _fix_cases() + _exit_cases())


def main(argv):
    parser = argparse.ArgumentParser(description="List WebKit's extension names for each catalog entry.")
    parser.add_argument("--catalog", default=DEFAULT_CATALOG)
    parser.add_argument("--dir", help="new or empty download folder, outside the repo")
    parser.add_argument("--only", nargs="+", metavar="ID")
    parser.add_argument("--check", action="store_true", help="compare with the committed alsoNamed")
    parser.add_argument("--keep", action="store_true", help="keep a temporary download folder")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if not sys.flags.isolated:
        die("run this as: python3 -I scripts/catalog_extension_names.py")
    return self_test() if args.self_test else run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
