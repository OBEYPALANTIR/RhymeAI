#!/usr/bin/env python3
"""Generate the deterministic iOS/Android RAI1, RAI2 and RAI3 test vectors.

From the repository root:
  python3 scripts/generate-sync-envelope-vectors.py android/app/src/test/resources/sync-envelope-vectors.json
Requires cryptography 50.0.2; this generator is independent of Kotlin and CryptoKit.
"""
import base64
import hashlib
import json
import sys
from pathlib import Path

import cryptography
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

PASSPHRASE = "correct horse battery staple"
SALT = bytes(range(16))
IV = bytes(range(0x10, 0x1C))
V1 = '{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}'
# The deletion identities/timestamps match SyncRepairContractTests.swift:41.
V2 = ('{"version":2,"projects":[],"trashed":[],"recordings":[],"deletions":['
      '{"projectId":"gone","fileName":null,"deletedAt":1},'
      '{"projectId":"gone","fileName":null,"deletedAt":2},'
      '{"projectId":"gone","fileName":"take.m4a","deletedAt":9223372036854775807},'
      '{"projectId":"keep","fileName":"removed.m4a","deletedAt":3}],'
      '"savedAt":2000000000000,"savedByClientId":"deleter"}')
# v3 keeps the v2 body shape; the version marks manifests that may list imported recordings.
V3 = V2.replace('"version":2', '"version":3', 1)


def vector(magic: str, plaintext: str) -> dict:
    header = magic.encode("ascii") + SALT + IV
    key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=SALT, iterations=210_000).derive(PASSPHRASE.encode("utf-8"))
    envelope = header + AESGCM(key).encrypt(IV, plaintext.encode("utf-8"), header)
    return {
        "magic": magic,
        "plaintext": plaintext,
        "plaintext_sha256": hashlib.sha256(plaintext.encode("utf-8")).hexdigest(),
        "envelope_base64": base64.b64encode(envelope).decode("ascii"),
        "envelope_sha256": hashlib.sha256(envelope).hexdigest(),
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate-sync-envelope-vectors.py OUTPUT.json")
    output = {
        "generator": "python3 scripts/generate-sync-envelope-vectors.py android/app/src/test/resources/sync-envelope-vectors.json",
        "cryptography_version": cryptography.__version__,
        "kdf": "PBKDF2-HMAC-SHA256/210000/32",
        "cipher": "AES-256-GCM, 12-byte IV, 16-byte tag, AAD=actual magic||salt||IV",
        "passphrase": PASSPHRASE,
        "salt_hex": SALT.hex(),
        "iv_hex": IV.hex(),
        "vectors": [vector("RAI1", V1), vector("RAI2", V2), vector("RAI3", V3)],
    }
    Path(sys.argv[1]).write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
