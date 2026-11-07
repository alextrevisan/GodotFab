#!/usr/bin/env python3
"""Generate Epic build manifest and chunk fixtures for tests/test_manifest.gd.

Deterministic (fixed seed). Run from the project root:
    python3 -I tests/fixtures/make_manifest_fixtures.py

Writes next to this script:
    manifest_v20.manifest   binary manifest, feature level 20, zlib body
    manifest_v22.manifest   binary manifest, feature level 22 (chunk secrets/tags), zlib body
    manifest.json           JSON manifest with the same files and chunks (feature level 20)
    chunk_compressed.chunk  chunk c1, zlib payload
    chunk_plain.chunk       chunk c2, raw payload
    expected.json           what the parser must produce for all of the above
"""

from __future__ import annotations

import base64
import hashlib
import json
import random
import struct
import zlib
from pathlib import Path

MANIFEST_MAGIC = 0x44BEC00C
CHUNK_MAGIC = 0xB1FE3AA2

OUT = Path(__file__).resolve().parent

GUID_C1 = (0x11111111, 0x22222222, 0x33333333, 0x44444444)
GUID_C2 = (0xAAAAAAAA, 0xBBBBBBBB, 0xCCCCCCCC, 0xDDDDDDDD)
HASH_C1 = 0x0123456789ABCDEF
HASH_C2 = 0xFEDCBA9876543210  # high bit set: exercises signed 64-bit handling in GDScript
GROUP_C1 = 7
GROUP_C2 = 99
SECRET_C1 = (1, 2, 3, 4)
SECRET_C2 = (0, 0, 0, 0)  # all zero => "plain" folder at feature level 22
BUILD_VERSION = "1.0.0"


# --- binary builders (Epic layout, little-endian) --------------------------------------------

def fstring(text: str) -> bytes:
    if not text:
        return struct.pack("<i", 0)
    try:
        return struct.pack("<i", len(text) + 1) + text.encode("ascii") + b"\0"
    except UnicodeEncodeError:
        return struct.pack("<i", -(len(text) + 1)) + text.encode("utf-16-le") + b"\0\0"


def section(body: bytes) -> bytes:
    return struct.pack("<I", 4 + len(body)) + body


def meta(feature_level: int, build_version: str, data_version: int, prereq_name: str = "", extra: bytes = b"") -> bytes:
    body = struct.pack("<BIBI", data_version, feature_level, 0, 0)
    body += fstring("FabPack") + fstring(build_version) + fstring("") + fstring("")
    body += struct.pack("<I", 1) + fstring("prerequisite")
    body += fstring(prereq_name) + fstring("") + fstring("")
    if data_version >= 1:
        body += fstring("build-id")
    if data_version >= 2:
        body += fstring("") * 2
    return section(body + extra)


def chunk_list(chunks: list[dict], feature_level: int) -> bytes:
    count = len(chunks)
    body = struct.pack("<BI", 3, count)
    body += b"".join(struct.pack("<IIII", *c["guid"]) for c in chunks)
    body += b"".join(struct.pack("<Q", c["hash"]) for c in chunks)
    body += b"".join(c["sha1"] for c in chunks)
    body += bytes(c["group"] for c in chunks)
    body += struct.pack("<I", 1 << 20) * count
    body += b"".join(struct.pack("<q", len(c["payload"])) for c in chunks)
    if feature_level >= 22:
        body += b"".join(struct.pack("<IIII", *c["secret"]) for c in chunks)
        body += struct.pack("<I", 0) * count
        body += b"\x5a" * 16 * count  # encryption tags
    return section(body)


def file_list(files: list[dict], version: int = 2) -> bytes:
    count = len(files)
    body = struct.pack("<BI", version, count)
    body += b"".join(fstring(f["filename"]) for f in files)
    body += fstring("") * count  # symlink targets
    body += b"".join(f["sha1"] for f in files)
    body += b"\0" * count  # flags
    body += (struct.pack("<I", 1) + fstring("tag")) * count  # install tags
    for f in files:
        body += struct.pack("<I", len(f["parts"]))
        for guid, offset, size in f["parts"]:
            body += struct.pack("<I", 28) + struct.pack("<IIII", *guid) + struct.pack("<II", offset, size)
    if version >= 1:
        body += struct.pack("<I", 0) * count  # no MD5
        body += fstring("application/octet-stream") * count
    if version >= 2:
        body += b"\0" * 32 * count  # SHA-256
    return section(body)


def custom_fields() -> bytes:
    return section(struct.pack("<BI", 0, 0))


def binary_manifest(body: bytes) -> bytes:
    data = zlib.compress(body)
    header = struct.pack("<IIII", MANIFEST_MAGIC, 41, len(body), len(data))
    header += hashlib.sha1(body).digest()
    header += struct.pack("<BI", 1, 18)
    return header + data


def chunk_file(guid: tuple, payload: bytes, *, compressed: bool) -> bytes:
    data = zlib.compress(payload) if compressed else payload
    header = struct.pack("<IIII", CHUNK_MAGIC, 3, 66, len(data))
    header += struct.pack("<IIII", *guid) + struct.pack("<Q", 0) + struct.pack("<B", 1 if compressed else 0)
    header += hashlib.sha1(payload).digest() + struct.pack("<B", 2) + struct.pack("<I", len(payload))
    assert len(header) == 66
    return header + data


# --- JSON builders ------------------------------------------------------------------------------

def blob(value: int, size: int) -> str:
    return "".join(f"{byte:03d}" for byte in value.to_bytes(size, "little"))


def bytes_blob(data: bytes) -> str:
    return "".join(f"{byte:03d}" for byte in data)


def guid_hex(guid: tuple) -> str:
    return "".join(f"{part:08X}" for part in guid)


def json_manifest(feature_level: int, chunks: list[dict], files: list[dict]) -> bytes:
    document = {
        "ManifestFileVersion": blob(feature_level, 4),
        "bIsFileData": False,
        "AppID": blob(0, 4),
        "AppNameString": "FabPack",
        "BuildVersionString": BUILD_VERSION,
        "LaunchExeString": "",
        "LaunchCommand": "",
        "PrereqIds": [],
        "PrereqName": "",
        "PrereqPath": "",
        "PrereqArgs": "",
        "FileManifestList": [
            {
                "Filename": f["filename"],
                "FileHash": bytes_blob(f["sha1"]),
                "FileChunkParts": [
                    {"Guid": guid_hex(guid), "Offset": blob(offset, 4), "Size": blob(size, 4)}
                    for guid, offset, size in f["parts"]
                ],
            }
            for f in files
        ],
        "ChunkHashList": {guid_hex(c["guid"]): blob(c["hash"], 8) for c in chunks},
        "ChunkShaList": {guid_hex(c["guid"]): c["sha1"].hex().upper() for c in chunks},
        "DataGroupList": {guid_hex(c["guid"]): blob(c["group"], 1) for c in chunks},
        "ChunkFilesizeList": {guid_hex(c["guid"]): blob(len(c["payload"]), 8) for c in chunks},
        "CustomFields": {},
    }
    return json.dumps(document, indent=1).encode()


# --- chunk CDN paths (reference rule) ----------------------------------------------------------

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().strip("=")


def chunk_folder(feature_level: int) -> str:
    if feature_level >= 22:
        return "ChunksV5"
    if feature_level >= 15:
        return "ChunksV4"
    if feature_level >= 6:
        return "ChunksV3"
    if feature_level >= 3:
        return "ChunksV2"
    return "Chunks"


def chunk_path(chunk: dict, feature_level: int, secret: tuple | None) -> str:
    folder = chunk_folder(feature_level)
    if feature_level >= 22:
        secret_part = "plain" if secret is None or secret == (0, 0, 0, 0) else b64url(struct.pack("<IIII", *secret))
        hash_part = b64url(struct.pack("<Q", chunk["hash"]))
        guid_part = b64url(struct.pack("<IIII", *chunk["guid"]))
        return f"{folder}/{secret_part}/{chunk['group']:02d}/{hash_part}_{guid_part}.chunk"
    return f"{folder}/{chunk['group']:02d}/{chunk['hash']:016X}_{guid_hex(chunk['guid'])}.chunk"


# --- main --------------------------------------------------------------------------------------

def main() -> None:
    rng = random.Random(20261106)
    payload_c1 = rng.randbytes(3000)
    payload_c2 = rng.randbytes(5000)

    chunks = [
        {"guid": GUID_C1, "hash": HASH_C1, "group": GROUP_C1, "secret": SECRET_C1, "payload": payload_c1},
        {"guid": GUID_C2, "hash": HASH_C2, "group": GROUP_C2, "secret": SECRET_C2, "payload": payload_c2},
    ]
    for c in chunks:
        c["sha1"] = hashlib.sha1(c["payload"]).digest()

    # A.uasset = c1[100:2100] + c2[0:1500]; Overview.umap = c2[1500:5000]
    a_parts = [(GUID_C1, 100, 2000), (GUID_C2, 0, 1500)]
    a_content = payload_c1[100:2100] + payload_c2[0:1500]
    map_parts = [(GUID_C2, 1500, 3500)]
    map_content = payload_c2[1500:5000]
    files = [
        {"filename": "Content/Pack/Meshes/A.uasset", "sha1": hashlib.sha1(a_content).digest(), "parts": a_parts, "content": a_content},
        {"filename": "Content/Pack/Maps/Overview.umap", "sha1": hashlib.sha1(map_content).digest(), "parts": map_parts, "content": map_content},
    ]

    body_v20 = meta(20, BUILD_VERSION, 2) + chunk_list(chunks, 20) + file_list(files, 2) + custom_fields()
    # v22: a UTF-16 string in the metadata and trailing unknown bytes the parser must skip.
    body_v22 = (
        meta(22, BUILD_VERSION, 2, prereq_name="Pré-requisito Ünïcode", extra=b"future-field")
        + chunk_list(chunks, 22)
        + file_list(files, 2)
        + custom_fields()
    )

    (OUT / "manifest_v20.manifest").write_bytes(binary_manifest(body_v20))
    (OUT / "manifest_v22.manifest").write_bytes(binary_manifest(body_v22))
    (OUT / "manifest.json").write_bytes(json_manifest(20, chunks, files))
    (OUT / "chunk_compressed.chunk").write_bytes(chunk_file(GUID_C1, payload_c1, compressed=True))
    (OUT / "chunk_plain.chunk").write_bytes(chunk_file(GUID_C2, payload_c2, compressed=False))

    expected = {
        "build_version": BUILD_VERSION,
        "feature_level": {"v20": 20, "v22": 22, "json": 20},
        "chunks": {
            guid_hex(c["guid"]): {
                "guid": list(c["guid"]),
                "hash_hex": f"{c['hash']:016X}",
                "group": c["group"],
                "secret_v22": None if c["secret"] == (0, 0, 0, 0) else list(c["secret"]),
                "path_v20": chunk_path(c, 20, None),
                "path_v22": chunk_path(c, 22, c["secret"]),
                "payload_size": len(c["payload"]),
                "payload_sha1_hex": c["sha1"].hex(),
            }
            for c in chunks
        },
        "files": [
            {
                "filename": f["filename"],
                "size": len(f["content"]),
                "sha1_hex": f["sha1"].hex(),
                "parts": [{"guid": guid_hex(g), "offset": o, "size": s} for g, o, s in f["parts"]],
            }
            for f in files
        ],
        "chunk_compressed": {"guid": guid_hex(GUID_C1), "payload_size": len(payload_c1), "payload_sha1_hex": hashlib.sha1(payload_c1).hexdigest()},
        "chunk_plain": {"guid": guid_hex(GUID_C2), "payload_size": len(payload_c2), "payload_sha1_hex": hashlib.sha1(payload_c2).hexdigest()},
        "chunk_paths_by_level": {
            str(level): chunk_path(chunks[0], level, None) for level in (2, 5, 14, 18)
        },
    }
    (OUT / "expected.json").write_text(json.dumps(expected, indent=1) + "\n")
    print("wrote fixtures to", OUT)


if __name__ == "__main__":
    main()
