#!/usr/bin/env python3
"""Inject Dolby Vision RPU NAL units into an Annex-B HEVC elementary stream.

Usage: dv_inject.py <in.hevc> <rpus.bin> <out.hevc>

rpus.bin is the output of scripts/dvgen: a sequence of (4-byte big-endian length,
NAL bytes starting with the 0x7C01 UNSPEC62 header). One RPU is appended after
each picture's VCL NAL unit (single-slice pictures, as produced by x265).
Development tool for the synthetic test clips only.
"""
import struct
import sys


def split_annexb(data: bytes):
    """Yield NAL unit payloads (without start codes) from an Annex-B stream."""
    i, n, starts = 0, len(data), []
    while i + 3 <= n:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append(i + 3)
            i += 3
        else:
            i += 1
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else n
        # Trim the extra zero byte of 4-byte start codes / trailing zeros.
        while e > s and data[e - 1] == 0:
            e -= 1
        yield data[s:e]


def read_rpus(path: str):
    rpus, data, i = [], open(path, "rb").read(), 0
    while i < len(data):
        (length,) = struct.unpack(">I", data[i:i + 4])
        rpus.append(data[i + 4:i + 4 + length])
        i += 4 + length
    return rpus


def main():
    src, rpu_path, dst = sys.argv[1:4]
    rpus = read_rpus(rpu_path)
    out, used = bytearray(), 0
    for nal in split_annexb(open(src, "rb").read()):
        out += b"\x00\x00\x00\x01" + nal
        nal_type = (nal[0] >> 1) & 0x3F
        if nal_type <= 31:  # VCL NAL unit: end of this (single-slice) picture
            if used >= len(rpus):
                sys.exit(f"error: more pictures than RPUs ({len(rpus)})")
            out += b"\x00\x00\x00\x01" + rpus[used]
            used += 1
    open(dst, "wb").write(out)
    print(f"injected {used} RPUs", file=sys.stderr)


if __name__ == "__main__":
    main()
