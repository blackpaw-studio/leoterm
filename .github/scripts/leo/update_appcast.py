"""
Add a release to Leo's Sparkle appcast.

Adapted from dist/macos/update_appcast_tag.py for GitHub-hosted releases.

Inputs (current directory):
    sign_update.txt  output of Sparkle's `sign_update` for Leo.dmg
    appcast.xml      previous appcast (optional; a fresh one is created)
Environment:
    LEO_VERSION, LEO_BUILD, LEO_COMMIT, LEO_COMMIT_LONG, LEO_TAG, LEO_REPO
Output:
    appcast_new.xml
"""

import os
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

PRUNE_AMOUNT = 15
PUBDATE_FORMAT = "%a, %d %b %Y %H:%M:%S %z"
MINIMUM_SYSTEM_VERSION = "13.0.0"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NAMESPACES = {"sparkle": SPARKLE_NS}


def parse_sign_update(text):
    """Parse `key="value" key2="value2"` pairs; values may contain '='."""
    attrs = {}
    for pair in text.split():
        key, value = pair.split("=", 1)
        attrs[key] = value.strip().strip('"')
    if "sparkle:edSignature" not in attrs or "length" not in attrs:
        raise SystemExit("sign_update.txt is missing edSignature/length")
    return attrs


def load_channel():
    if os.path.exists("appcast.xml") and os.path.getsize("appcast.xml") > 0:
        tree = ET.parse("appcast.xml")
        channel = tree.find("channel")
        if channel is None:
            raise SystemExit("appcast.xml has no <channel>")
        return tree, channel
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Leo"
    return ET.ElementTree(rss), channel


def prune(channel, build):
    # Duplicate versions make Sparkle report invalid signatures, and items
    # without a pubDate can't be ordered.
    for item in list(channel.findall("item")):
        version = item.find("sparkle:version", NAMESPACES)
        if (version is not None and version.text == build) or item.find("pubDate") is None:
            channel.remove(item)
    items = sorted(
        channel.findall("item"),
        key=lambda i: datetime.strptime(i.find("pubDate").text, PUBDATE_FORMAT),
    )
    for item in items[: max(0, len(items) - (PRUNE_AMOUNT - 1))]:
        channel.remove(item)


def add_item(channel, env, attrs, now):
    release_url = f"{env['repo']}/releases/tag/{env['tag']}"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Leo {env['version']}"
    ET.SubElement(item, "pubDate").text = now.strftime(PUBDATE_FORMAT)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = env["build"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = env["version"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = MINIMUM_SYSTEM_VERSION
    ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = release_url
    ET.SubElement(item, "description").text = (
        f"<h1>Leo {env['version']}</h1>"
        f"<p>Built from commit <code><a href=\"{env['repo']}/commit/{env['commit_long']}\">"
        f"{env['commit']}</a></code> on {now.strftime('%Y-%m-%d')}.</p>"
        f"<p>Release notes: <a href=\"{release_url}\">{release_url}</a></p>"
    )
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", f"{env['repo']}/releases/download/{env['tag']}/Leo.dmg")
    enclosure.set("type", "application/octet-stream")
    for key, value in attrs.items():
        name = f"{{{SPARKLE_NS}}}{key.split(':', 1)[1]}" if key.startswith("sparkle:") else key
        enclosure.set(name, value)


def main():
    env = {
        key: os.environ[f"LEO_{key.upper()}"]
        for key in ("version", "build", "commit", "commit_long", "tag", "repo")
    }
    for prefix, uri in NAMESPACES.items():
        ET.register_namespace(prefix, uri)
    with open("sign_update.txt") as f:
        attrs = parse_sign_update(f.read())
    tree, channel = load_channel()
    prune(channel, env["build"])
    add_item(channel, env, attrs, datetime.now(timezone.utc))
    tree.write("appcast_new.xml", xml_declaration=True, encoding="utf-8")


if __name__ == "__main__":
    main()
