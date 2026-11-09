#!/usr/bin/env python3
"""Makes the Authenticode test fixtures: a tiny Windows program (PE32+, no code) signed the
way publishers sign installers, by a throwaway test certificate authority.

    python3 Tests/DistillerCoreTests/Fixtures/make-authenticode-fixtures.py

Writes, next to this script:
  authenticode-signed.exe       signed by "Distiller Test Publisher" (code signing)
  authenticode-wrong-usage.exe  signed by a certificate that isn't for code signing
  authenticode-root.cer         the test root, which the tests trust explicitly

The keys live in a temporary folder and are deleted, so nothing secret is kept. Needs openssl.
Built from Microsoft's Authenticode specification and PKCS #7 (RFC 2315).
"""
import hashlib
import struct
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def der(tag: int, value: bytes) -> bytes:
    n = len(value)
    if n < 0x80:
        length = bytes([n])
    else:
        raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
        length = bytes([0x80 | len(raw)]) + raw
    return bytes([tag]) + length + value


def seq(*parts: bytes) -> bytes:
    return der(0x30, b"".join(parts))


def der_set(*parts: bytes) -> bytes:
    return der(0x31, b"".join(sorted(parts)))


def oid(dotted: str) -> bytes:
    numbers = [int(x) for x in dotted.split(".")]
    body = bytes([40 * numbers[0] + numbers[1]])
    for number in numbers[2:]:
        chunk = [number & 0x7F]
        number >>= 7
        while number:
            chunk.insert(0, 0x80 | (number & 0x7F))
            number >>= 7
        body += bytes(chunk)
    return der(0x06, body)


NULL = b"\x05\x00"
SHA256 = seq(oid("2.16.840.1.101.3.4.2.1"), NULL)


def tlv(buffer: bytes, offset: int):
    tag = buffer[offset]
    length = buffer[offset + 1]
    start = offset + 2
    if length & 0x80:
        count = length & 0x7F
        length = int.from_bytes(buffer[start:start + count], "big")
        start += count
    return tag, offset, start, start + length


def children(buffer: bytes, start: int, end: int):
    result, cursor = [], start
    while cursor < end:
        element = tlv(buffer, cursor)
        result.append(element)
        cursor = element[3]
    return result


def issuer_and_serial(certificate: bytes) -> bytes:
    _, _, start, end = tlv(certificate, 0)
    tbs = children(certificate, start, end)[0]
    fields = children(certificate, tbs[2], tbs[3])
    if fields[0][0] == 0xA0:
        fields = fields[1:]
    serial, issuer = fields[0], fields[2]
    return seq(certificate[issuer[1]:issuer[3]], certificate[serial[1]:serial[3]])


def program() -> bytearray:
    """A PE32+ header (no sections, 16 data directories) and some bytes to sign."""
    data = bytearray(0x200)
    data[0:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 0x84, 0x8664, 0, 0, 0, 0, 240, 0x22)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20B)
    struct.pack_into("<I", data, optional + 108, 16)
    data += (b"Distiller Authenticode test program. Not a game; not runnable. " * 16)[:0x400]
    return data


def sign(unsigned: bytearray, leaf: bytes, root: bytes, key: Path, work: Path) -> bytes:
    checksum = 0x98 + 64
    directory = 0x98 + 112 + 4 * 8
    image = bytes(unsigned)
    digest = hashlib.sha256(image[:checksum] + image[checksum + 4:directory] + image[directory + 8:]).digest()

    spc = seq(
        seq(oid("1.3.6.1.4.1.311.2.1.15"), seq(der(0x03, b"\x00"))),
        seq(SHA256, der(0x04, digest)),
    )
    spc_value = spc[tlv(spc, 0)[2]:]
    attributes = [
        seq(oid("1.2.840.113549.1.9.3"), der_set(oid("1.3.6.1.4.1.311.2.1.4"))),
        seq(oid("1.2.840.113549.1.9.4"), der_set(der(0x04, hashlib.sha256(spc_value).digest()))),
    ]
    signed_attributes = der_set(*attributes)
    (work / "attributes.der").write_bytes(signed_attributes)
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key), "-out", str(work / "signature.bin"),
                    str(work / "attributes.der")], check=True)
    signature = (work / "signature.bin").read_bytes()

    signer_info = seq(
        der(0x02, b"\x01"), issuer_and_serial(leaf), SHA256,
        der(0xA0, signed_attributes[tlv(signed_attributes, 0)[2]:]),
        seq(oid("1.2.840.113549.1.1.1"), NULL), der(0x04, signature),
    )
    signed_data = seq(
        der(0x02, b"\x01"), der_set(SHA256),
        seq(oid("1.3.6.1.4.1.311.2.1.4"), der(0xA0, spc)),
        der(0xA0, leaf + root), der_set(signer_info),
    )
    blob = seq(oid("1.2.840.113549.1.7.2"), der(0xA0, signed_data))
    padded = blob + b"\0" * (-(len(blob) + 8) % 8)
    table = struct.pack("<IHH", 8 + len(padded), 0x0200, 0x0002) + padded

    signed = bytearray(unsigned)
    struct.pack_into("<II", signed, directory, len(signed), len(table))
    return bytes(signed + table)


def openssl(*arguments: str, cwd: Path) -> None:
    subprocess.run(["openssl", *arguments], check=True, cwd=cwd, capture_output=True)


def main() -> None:
    with tempfile.TemporaryDirectory() as folder:
        work = Path(folder)
        (work / "leaf.ext").write_text("basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=codeSigning\n")
        (work / "server.ext").write_text("basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n")
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "root.key", "-out", "root.pem", "-days", "36500",
                "-subj", "/CN=Distiller Test Root", "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign", cwd=work)
        for name, ext, common in [("leaf", "leaf.ext", "Distiller Test Publisher"), ("server", "server.ext", "Distiller Test Website")]:
            openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{name}.key", "-out", f"{name}.csr",
                    "-subj", f"/O=Distiller Tests/CN={common}", cwd=work)
            openssl("x509", "-req", "-in", f"{name}.csr", "-CA", "root.pem", "-CAkey", "root.key", "-CAcreateserial",
                    "-out", f"{name}.pem", "-days", "36500", "-extfile", ext, cwd=work)
            openssl("x509", "-in", f"{name}.pem", "-outform", "DER", "-out", f"{name}.der", cwd=work)
        openssl("x509", "-in", "root.pem", "-outform", "DER", "-out", "root.der", cwd=work)
        root = (work / "root.der").read_bytes()

        (HERE / "authenticode-signed.exe").write_bytes(sign(program(), (work / "leaf.der").read_bytes(), root, work / "leaf.key", work))
        (HERE / "authenticode-wrong-usage.exe").write_bytes(sign(program(), (work / "server.der").read_bytes(), root, work / "server.key", work))
        (HERE / "authenticode-root.cer").write_bytes(root)
    print("Wrote authenticode-signed.exe, authenticode-wrong-usage.exe and authenticode-root.cer")


if __name__ == "__main__":
    main()
