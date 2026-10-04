"""Strict DNS response checks used by production ProbeSelfCheck."""
from __future__ import annotations


def parse_dns_name(data: bytes, offset: int) -> tuple[str, int]:
    labels: list[str] = []
    jumped = False
    end = offset
    hops = 0
    while hops < 20 and offset < len(data):
        length = data[offset]
        if length == 0:
            if not jumped:
                end = offset + 1
            return ".".join(labels), end
        if (length & 0xC0) == 0xC0:
            if offset + 1 >= len(data):
                raise ValueError("truncated pointer")
            ptr = ((length & 0x3F) << 8) | data[offset + 1]
            if not jumped:
                end = offset + 2
            offset = ptr
            jumped = True
            hops += 1
            continue
        offset += 1
        if offset + length > len(data):
            raise ValueError("truncated label")
        labels.append(data[offset : offset + length].decode("ascii", "replace").lower())
        offset += length
        if not jumped:
            end = offset
        hops += 1
    raise ValueError("name overflow")


def build_dns_query(name: str, txid: int) -> bytes:
    labels = name.split(".")
    q = bytearray(12)
    q[0] = (txid >> 8) & 0xFF
    q[1] = txid & 0xFF
    q[2] = 0x01
    q[5] = 0x01
    for lab in labels:
        raw = lab.encode("ascii")
        q.append(len(raw))
        q.extend(raw)
    q.append(0)
    q.extend(b"\x00\x01\x00\x01")
    return bytes(q)


def validate_dns_response(
    *,
    payload: bytes,
    txid: int,
    question: str,
    source: str,
    source_port: int,
    expect_source: str = "8.8.8.8",
    expect_port: int = 53,
) -> bool:
    if source != expect_source or source_port != expect_port:
        return False
    if len(payload) < 12:
        return False
    got_txid = (payload[0] << 8) | payload[1]
    if got_txid != txid:
        return False
    flags = (payload[2] << 8) | payload[3]
    qr = (flags >> 15) & 1
    rcode = flags & 0x0F
    if qr != 1 or rcode != 0:
        return False
    qd = (payload[4] << 8) | payload[5]
    an = (payload[6] << 8) | payload[7]
    if qd != 1 or an < 1:
        return False
    try:
        name, off = parse_dns_name(payload, 12)
    except ValueError:
        return False
    if name != question.lower():
        return False
    if off + 4 > len(payload):
        return False
    qtype = (payload[off] << 8) | payload[off + 1]
    qclass = (payload[off + 2] << 8) | payload[off + 3]
    if qtype != 1 or qclass != 1:
        return False
    off += 4
    owner = question.lower()
    saw_a = False
    for _ in range(an):
        try:
            rr_name, off = parse_dns_name(payload, off)
        except ValueError:
            return False
        if rr_name != owner:
            return False
        if off + 10 > len(payload):
            return False
        atype = (payload[off] << 8) | payload[off + 1]
        aclass = (payload[off + 2] << 8) | payload[off + 3]
        rdlen = (payload[off + 8] << 8) | payload[off + 9]
        off += 10
        if aclass != 1 or rdlen < 1 or off + rdlen > len(payload):
            return False
        if atype == 1:
            if rdlen != 4:
                return False
            saw_a = True
            break
        if atype == 5:
            try:
                owner, _ = parse_dns_name(payload, off)
            except ValueError:
                return False
            off += rdlen
            continue
        return False
    return saw_a
