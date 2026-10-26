#!/usr/bin/env python3
"""App Store Connect API helper for Speech Key's Mac App Store build. Standard library plus the
openssl command line only.

Needs an App Store Connect API key (Users and Access > Integrations > Team Keys, role Admin): the
.p8 file in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, and ASC_KEY_ID and ASC_ISSUER_ID
in the environment or in ~/.appstoreconnect/asc.env (KEY=value lines; neither ID is secret). The same
key serves Sean's other apps (Sean OS).

  scripts/asc.py setup    register the bundle ID, create the two Mac App Store certificates (into
                          the login keychain, usable by codesign and productbuild without a
                          prompt), and download the provisioning profile to dist/appstore/
  scripts/asc.py get PATH print any API resource, e.g. /v1/apps?filter[bundleId]=com.seanblundin.utter
"""
import base64, json, os, pathlib, re, secrets, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

BUNDLE_ID = "com.seanblundin.utter"
APP_NAME = "Speech Key"
PROFILE_NAME = "Speech Key Mac App Store"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "dist" / "appstore"


def config():
    env = dict(os.environ)
    for f in [pathlib.Path.home() / ".appstoreconnect/asc.env", pathlib.Path.home() / ".config/speech-key/asc.env"]:
        if f.exists():
            for line in f.read_text().splitlines():
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.split("=", 1)
                    env.setdefault(k.strip(), v.strip().strip('"'))
    key_id, issuer = env.get("ASC_KEY_ID"), env.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit("Set ASC_KEY_ID and ASC_ISSUER_ID (see the top of this script).")
    p8 = pathlib.Path.home() / f".appstoreconnect/private_keys/AuthKey_{key_id}.p8"
    if not p8.exists():
        sys.exit(f"Missing {p8}")
    return key_id, issuer, p8


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der):
    # ECDSA signature: SEQUENCE { INTEGER r, INTEGER s } -> r || s, 32 bytes each.
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        out += der[i + 2:i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + n
    return out


def token():
    key_id, issuer, p8 = config()
    now = int(time.time())
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(p8)], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64url(der_to_raw(der))}"


def api(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} failed ({e.code}): {e.read().decode()[:800]}")


def bundle_id():
    found = api("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}&limit=5")["data"]
    exact = [b for b in found if b["attributes"]["identifier"] == BUNDLE_ID]
    if exact:
        print(f"bundle ID {BUNDLE_ID} already registered")
        return exact[0]["id"]
    made = api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": APP_NAME, "platform": "MAC_OS"}}})
    print(f"registered bundle ID {BUNDLE_ID}")
    return made["data"]["id"]


def keychain_serials():
    """Serial numbers of the signing identities (certificate and private key) in the keychain."""
    found = set()
    ids = subprocess.run(["security", "find-identity", "-v"], capture_output=True, text=True).stdout
    for name in set(re.findall(r'"([^"]+)"', ids)):
        pems = subprocess.run(["security", "find-certificate", "-a", "-c", name, "-p"], capture_output=True, text=True).stdout
        for pem in pems.split("-----END CERTIFICATE-----"):
            if "BEGIN CERTIFICATE" not in pem:
                continue
            out = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem + "-----END CERTIFICATE-----\n",
                                 capture_output=True, text=True).stdout
            found.add(out.strip().split("=")[-1].upper().lstrip("0"))
    return found


def certificate(kinds, label):
    """A certificate of one of `kinds` whose private key is in the login keychain (matched by
    serial number), or a new one of the first kind: a key and CSR made here, signed by Apple."""
    have = keychain_serials()
    for kind in kinds:
        for c in api("GET", f"/v1/certificates?filter[certificateType]={kind}&limit=50")["data"]:
            if c["attributes"]["serialNumber"].upper().lstrip("0") in have:
                print(f"{label}: using {c['attributes']['name']} ({c['attributes']['displayName']}), already in the keychain")
                return c["id"]
    kind = kinds[0]
    with tempfile.TemporaryDirectory() as tmp:
        t = pathlib.Path(tmp)
        subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", t / "key.pem",
                        "-out", t / "req.csr", "-subj", f"/CN={APP_NAME} {label}"], check=True, capture_output=True)
        csr = (t / "req.csr").read_text()
        made = api("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
            "certificateType": kind, "csrContent": csr}}})["data"]
        (t / "cert.der").write_bytes(base64.b64decode(made["attributes"]["certificateContent"]))
        subprocess.run(["openssl", "x509", "-inform", "DER", "-in", t / "cert.der", "-out", t / "cert.pem"], check=True)
        password = secrets.token_hex(12)
        subprocess.run(["openssl", "pkcs12", "-export", "-legacy", "-inkey", t / "key.pem", "-in", t / "cert.pem",
                        "-out", t / "id.p12", "-passout", "pass:" + password], check=True, capture_output=True)
        # -T: codesign and productbuild may use the key without asking.
        subprocess.run(["security", "import", t / "id.p12", "-k", str(pathlib.Path.home() / "Library/Keychains/login.keychain-db"),
                        "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/productbuild",
                        "-T", "/usr/bin/productsign"], check=True)
        print(f"{label}: created ({made['attributes']['displayName']}) and imported into the login keychain")
        return made["id"]


def profile(bundle, cert):
    for p in api("GET", f"/v1/profiles?filter[name]={urllib.parse.quote(PROFILE_NAME)}&limit=10")["data"]:
        api("DELETE", f"/v1/profiles/{p['id']}")   # remade so it names today's certificate
    made = api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": PROFILE_NAME, "profileType": "MAC_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                          "certificates": {"data": [{"type": "certificates", "id": cert}]}}}})["data"]
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "SpeechKey_MAS.provisionprofile"
    path.write_bytes(base64.b64decode(made["attributes"]["profileContent"]))
    print(f"provisioning profile: {path}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "setup":
        b = bundle_id()
        # Apple Distribution (shared with Sean OS) signs the app; the installer certificate signs the .pkg.
        app_cert = certificate(["DISTRIBUTION", "MAC_APP_DISTRIBUTION"], "App signing")
        certificate(["MAC_INSTALLER_DISTRIBUTION"], "Installer signing")
        profile(b, app_cert)
    elif cmd == "get" and len(sys.argv) > 2:
        print(json.dumps(api("GET", sys.argv[2]), indent=2))
    else:
        print(__doc__)
