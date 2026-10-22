#!/usr/bin/env python3
"""Add a release to Sparkle's appcast.xml, or replace the entry for the same build.

Used by scripts/release.sh after the disk image has been signed with sign_update.
"""
from __future__ import annotations

import argparse
from email.utils import formatdate
from pathlib import Path
import re
import sys
from xml.sax.saxutils import escape

EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>DocuFind</title>
        <language>en</language>
    </channel>
</rss>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--check", action="store_true", help="Only check that the build number is free")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion, which Sparkle compares")
    parser.add_argument("--url", default="", help="Download address of the disk image")
    parser.add_argument("--signature", default="", help="EdDSA signature from sign_update")
    parser.add_argument("--length", default=0, type=int, help="Size of the disk image in bytes")
    parser.add_argument("--minimum-system", default="14.0")
    parser.add_argument("--release-notes-url", help="Optional page describing the release")
    args = parser.parse_args()

    feed = args.appcast.read_text(encoding="utf-8") if args.appcast.exists() else EMPTY_FEED
    items = re.findall(r"[ \t]*<item>.*?</item>\n?", feed, flags=re.S)
    for item in items:
        build = re.search(r"<sparkle:version>(.*?)</sparkle:version>", item)
        short = re.search(r"<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>", item)
        if build and build.group(1) == args.build:
            if short and short.group(1) != escape(args.version):
                print(f"Build {args.build} is already in the appcast as version {short.group(1)}. "
                      "Increase CFBundleVersion in Info.plist for every release.", file=sys.stderr)
                return 1
            feed = feed.replace(item, "")
    if args.check:
        return 0
    if not (args.url and args.signature and args.length):
        parser.error("--url, --signature and --length are required")

    url = escape(args.url, {'"': "&quot;"})
    signature = escape(args.signature, {'"': "&quot;"})
    notes = f"\n            <sparkle:releaseNotesLink>{escape(args.release_notes_url)}</sparkle:releaseNotesLink>" if args.release_notes_url else ""
    entry = f"""        <item>
            <title>DocuFind {escape(args.version)}</title>
            <pubDate>{formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{escape(args.build)}</sparkle:version>
            <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{escape(args.minimum_system)}</sparkle:minimumSystemVersion>{notes}
            <enclosure url="{url}" length="{args.length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>
"""
    # Newest first, right after the channel's own fields.
    anchor = re.search(r"[ \t]*<item>", feed) or re.search(r"[ \t]*</channel>", feed)
    if not anchor:
        print(f"{args.appcast} is not an RSS feed.", file=sys.stderr)
        return 1
    feed = feed[:anchor.start()] + entry + feed[anchor.start():]
    args.appcast.parent.mkdir(parents=True, exist_ok=True)
    args.appcast.write_text(feed, encoding="utf-8")
    print(f"Updated {args.appcast}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
