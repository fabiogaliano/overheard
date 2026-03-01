# /// script
# requires-python = ">=3.10"
# dependencies = ["shazamio"]
# ///
import asyncio
import json
import sys

from shazamio import Shazam


async def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: recognize.py <audio_file>"}))
        sys.exit(1)

    shazam = Shazam()
    result = await shazam.recognize(sys.argv[1])

    track = result.get("track")
    if not track:
        print(json.dumps({"match": False}))
        return

    sections = track.get("sections", [])
    metadata = {}
    for section in sections:
        if section.get("type") == "SONG":
            for item in section.get("metadata", []):
                metadata[item.get("title", "").lower()] = item.get("text", "")

    output = {
        "match": True,
        "title": track.get("title", ""),
        "artist": track.get("subtitle", ""),
        "album": metadata.get("album", None),
    }

    duration_ms = track.get("sections", [{}])[0].get("metapages", [{}])
    key = track.get("key")
    if key:
        output["shazamId"] = key

    print(json.dumps(output))


asyncio.run(main())
