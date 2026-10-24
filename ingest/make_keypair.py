"""Create an RSA key pair for Snowflake key-pair authentication.

Trial accounts have no SSO, so `authenticator = "externalbrowser"` fails; key-pair
auth works everywhere and needs no password or MFA prompt. The private key goes to
.snowflake/rsa_key.p8 (git-ignored). Run the printed SQL once in a Snowsight
worksheet to register the public key on your user.

Usage:
    python ingest/make_keypair.py
"""
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KEY_DIR = Path(__file__).resolve().parents[1] / ".snowflake"


def main() -> None:
    private = KEY_DIR / "rsa_key.p8"
    if private.exists():
        raise SystemExit(f"{private} already exists; delete it first to rotate the key.")
    KEY_DIR.mkdir(exist_ok=True)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    pem = key.public_key().public_bytes(serialization.Encoding.PEM,
                                        serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    body = "".join(line for line in pem.splitlines() if "-----" not in line)

    print(f"Private key written to {private}\n")
    print("Run this in a Snowsight worksheet (quotes keep usernames containing . or @ intact):\n")
    print("SET u = '\"' || CURRENT_USER() || '\"';")
    print(f"ALTER USER IDENTIFIER($u) SET RSA_PUBLIC_KEY = '{body}';\n")
    print('Then in config.toml: user = your LOGIN name (what you type to sign in), '
          'authenticator = "SNOWFLAKE_JWT", private_key_file = ".snowflake/rsa_key.p8"')


if __name__ == "__main__":
    main()
