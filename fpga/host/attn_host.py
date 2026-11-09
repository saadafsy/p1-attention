#!/usr/bin/env python3
"""attn_host: FPGA bring-up host (protocol in docs/phase6_fpga_guide.md 6.3.4).

Runs one attention inference over UART and checks it bit-exactly against
model/attn.py attn_fixed. Usage: attn_host.py --port /dev/ttyUSB1 [--n 16]
or --selftest (offline). Frame builders and parsers are pure so
tb/fpga_uart can import them without pyserial. Multi-byte fields are little-endian.
"""

import argparse
import random
import sys
import time
from pathlib import Path

# Protocol constants (guide 6.3.4)
CMD_PING = 0x50  # 'P'
CMD_LOAD_Q = 0x51  # 'Q'
CMD_LOAD_K = 0x4B  # 'K'
CMD_LOAD_V = 0x56  # 'V'
CMD_SET_NLEN = 0x4E  # 'N'
CMD_RUN = 0x52  # 'R'
CMD_STATUS = 0x53  # 'S'
CMD_READ_OUT = 0x4F  # 'O'
CMD_READ_CYCLES = 0x43  # 'C'

RESP_PING = 0xA5
RESP_NAK = 0x3F  # '?': not a command byte, so never confused with an echo

LOAD_CMDS = (CMD_LOAD_Q, CMD_LOAD_K, CMD_LOAD_V)
ROW_BYTES = 16


def to_u8(v):
    """Signed int in [-128, 127] (an ACT Q1.6 code) -> unsigned wire byte."""
    if not (-128 <= v <= 127):
        raise ValueError(f"ACT code out of range: {v}")
    return v & 0xFF


def from_u8(v):
    """Unsigned wire byte -> signed int8 (an ACT Q1.6 code)."""
    v &= 0xFF
    return v - 256 if v >= 128 else v


def build_ping():
    return bytes([CMD_PING])


def build_load_row(cmd, row, data16):
    """LOAD_Q/K/V frame: row (low 6 bits) and 16 signed codes, column 0 first."""
    if cmd not in LOAD_CMDS:
        raise ValueError(f"build_load_row: not a LOAD_* command: {cmd:#x}")
    if len(data16) != ROW_BYTES:
        raise ValueError(f"build_load_row: need {ROW_BYTES} data bytes, got {len(data16)}")
    return bytes([cmd, row & 0x3F] + [to_u8(v) for v in data16])


def build_set_nlen(n_len):
    """SET_NLEN frame, unvalidated so the device's NAK path can be tested."""
    return bytes([CMD_SET_NLEN, n_len & 0xFF])


def build_run():
    return bytes([CMD_RUN])


def build_status():
    return bytes([CMD_STATUS])


def build_read_out(row):
    return bytes([CMD_READ_OUT, row & 0x3F])


def build_read_cycles():
    return bytes([CMD_READ_CYCLES])


def is_nak(resp_byte):
    return resp_byte == RESP_NAK


def parse_status(status_byte):
    """Status byte: bit0 busy, bit1 done latch."""
    return {
        "busy": bool(status_byte & 0x1),
        "done": bool((status_byte >> 1) & 0x1),
    }


def decode_out_row(data):
    """16 wire bytes (column 0 first) -> 16 signed ACT codes."""
    if len(data) != ROW_BYTES:
        raise ValueError(f"decode_out_row: need {ROW_BYTES} bytes, got {len(data)}")
    return [from_u8(b) for b in data]


def decode_cycles(data):
    """4 little-endian wire bytes -> unsigned cycle_count."""
    if len(data) != 4:
        raise ValueError(f"decode_cycles: need 4 bytes, got {len(data)}")
    return int.from_bytes(data, byteorder="little", signed=False)


# A long BREAK (e.g. from a USB-UART bridge on port open) can produce a phantom
# byte and an unsolicited NAK, so stale bytes are drained before use.
def drain_bytes(read_fn, chunk_size=256):
    """Call read_fn(chunk_size) until it returns nothing; return all bytes read."""
    drained = bytearray()
    while True:
        chunk = read_fn(chunk_size)
        if not chunk:
            break
        drained.extend(chunk)
    return bytes(drained)


RESYNC_PING_COUNT = 18  # longest in-flight payload (row + 16 data) plus one command byte


def build_resync_frame():
    """18 PINGs: enough to finish any abandoned frame and land one real PING."""
    return build_ping() * RESYNC_PING_COUNT


def is_resynced(drained_tail):
    """Resynced only if the last drained byte is 0xA5 (earlier ones may precede a stray echo)."""
    return len(drained_tail) > 0 and drained_tail[-1] == RESP_PING


class SerialLink:
    """8N1 pyserial transport with one method per protocol command."""

    def __init__(self, port, baud=115200, timeout=2.0, drain_timeout=0.05):
        import serial  # lazy: this module must import without pyserial

        # Short timeout first to drain stale RX bytes that would offset every response.
        self._ser = serial.Serial(
            port,
            baudrate=baud,
            bytesize=8,
            parity="N",
            stopbits=1,
            timeout=drain_timeout,
        )
        self.drained_on_open = drain_bytes(lambda n: self._ser.read(n))
        self._ser.timeout = timeout

    def close(self):
        self._ser.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    def write(self, data):
        self._ser.write(bytes(data))

    def read(self, n):
        data = self._ser.read(n)
        if len(data) != n:
            raise TimeoutError(f"SerialLink.read: expected {n} bytes, got {len(data)}: {data!r}")
        return data

    def ping(self):
        self.write(build_ping())
        return self.read(1)[0]

    def load_row(self, cmd, row, data16):
        self.write(build_load_row(cmd, row, data16))
        return self.read(1)[0]

    def set_nlen(self, n_len):
        self.write(build_set_nlen(n_len))
        return self.read(1)[0]

    def run(self):
        self.write(build_run())
        return self.read(1)[0]

    def status(self):
        self.write(build_status())
        return parse_status(self.read(1)[0])

    def read_out_row(self, row):
        """READ_OUT; the device NAKs while busy, which raises instead of parsing as data."""
        self.write(build_read_out(row))
        first = self.read(1)
        if is_nak(first[0]):
            raise RuntimeError("READ_OUT NAKed: device busy; poll STATUS until done")
        return decode_out_row(first + self.read(ROW_BYTES - 1))

    def read_cycles(self):
        """READ_CYCLES; NAKs while busy, same handling as read_out_row."""
        self.write(build_read_cycles())
        first = self.read(1)
        if is_nak(first[0]):
            raise RuntimeError("READ_CYCLES NAKed: device busy; poll STATUS until done")
        return decode_cycles(first + self.read(3))

    def resync(self, settle_timeout=0.5):
        """Send 18 pings, drain until quiet, check the last byte; then reload all Q/K/V rows."""
        self.write(build_resync_frame())
        old_timeout = self._ser.timeout
        self._ser.timeout = settle_timeout
        try:
            tail = drain_bytes(lambda n: self._ser.read(n))
        finally:
            self._ser.timeout = old_timeout
        return is_resynced(tail)


def selftest():
    row = 5
    data = [max(-128, min(127, ((-1) ** i) * (i * 7 % 130))) for i in range(16)]
    assert len(data) == 16

    for cmd in LOAD_CMDS:
        frame = build_load_row(cmd, row, data)
        assert frame[0] == cmd
        assert frame[1] == row
        assert len(frame) == 2 + ROW_BYTES
        assert decode_out_row(bytes(frame[2:])) == data

    assert build_ping() == bytes([CMD_PING])
    assert build_set_nlen(16) == bytes([CMD_SET_NLEN, 16])
    assert build_set_nlen(64) == bytes([CMD_SET_NLEN, 64])
    assert build_set_nlen(0x81) == bytes([CMD_SET_NLEN, 0x81])  # sent as-is; the device NAKs it
    assert build_run() == bytes([CMD_RUN])
    assert build_status() == bytes([CMD_STATUS])
    assert build_read_out(3) == bytes([CMD_READ_OUT, 3])
    assert build_read_out(0x40) == bytes([CMD_READ_OUT, 0x00])  # low 6 bits only
    assert build_read_cycles() == bytes([CMD_READ_CYCLES])

    assert parse_status(0b00) == {"busy": False, "done": False}
    assert parse_status(0b01) == {"busy": True, "done": False}
    assert parse_status(0b10) == {"busy": False, "done": True}
    assert parse_status(0b11) == {"busy": True, "done": True}
    # bits 7:2 are ignored
    assert parse_status(0b11111110) == {"busy": False, "done": True}

    assert decode_cycles(bytes([0x01, 0x00, 0x00, 0x00])) == 1
    assert decode_cycles(bytes([0x00, 0x01, 0x00, 0x00])) == 256
    assert decode_cycles(bytes([0xFF, 0xFF, 0xFF, 0xFF])) == 0xFFFFFFFF

    assert is_nak(RESP_NAK)
    assert not is_nak(RESP_PING)
    assert not is_nak(CMD_PING)

    for v in (-128, -1, 0, 1, 127):
        assert from_u8(to_u8(v)) == v
    assert to_u8(-1) == 0xFF
    assert to_u8(127) == 0x7F
    assert to_u8(-128) == 0x80
    assert from_u8(0x80) == -128
    assert from_u8(0x7F) == 127

    try:
        to_u8(128)
    except ValueError:
        pass
    else:
        raise AssertionError("to_u8(128) must raise ValueError (out of ACT range)")

    canned = [b"\xa5\x3f", b"more", b""]

    def fake_read(_n):
        return canned.pop(0) if canned else b""

    assert drain_bytes(fake_read) == b"\xa5\x3fmore"

    def fake_read_already_quiet(_n):
        return b""

    assert drain_bytes(fake_read_already_quiet) == b""

    frame = build_resync_frame()
    assert len(frame) == RESYNC_PING_COUNT == 18
    assert set(frame) == {CMD_PING}

    assert not is_resynced(b"")
    assert not is_resynced(bytes([RESP_PING, RESP_NAK]))
    assert is_resynced(bytes([RESP_PING]))
    # stray echo of an abandoned command, then ping echoes
    assert is_resynced(bytes([CMD_LOAD_Q, RESP_PING, RESP_PING, RESP_PING]))

    print("attn_host --selftest: all encode/decode round trips PASS")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", help="serial device, e.g. /dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--n", type=int, default=16, help="n_len, multiple of 4 in [4, 64]")
    ap.add_argument("--seed", type=int, default=1, help="RNG seed for random Q/K/V")
    ap.add_argument(
        "--selftest",
        action="store_true",
        help="offline encode/decode round trip only; no device, no pyserial import",
    )
    args = ap.parse_args(argv)

    if args.selftest:
        selftest()
        return 0

    if not args.port:
        print("error: --port is required unless --selftest", file=sys.stderr)
        return 2
    if args.n % 4 != 0 or not (4 <= args.n <= 64):
        print("error: --n must be a multiple of 4 in [4, 64] (uarch.md 8.3)", file=sys.stderr)
        return 2

    # Deferred so --selftest does not need the model.
    root = Path(__file__).resolve().parent.parent.parent
    sys.path.insert(0, str(root / "model"))
    import attn as attn_model  # noqa: E402

    lut = attn_model.gen_exp_lut()
    rng = random.Random(args.seed)
    n, d = args.n, attn_model.D_DIM
    q = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    v = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]

    print(f"attn_host: port={args.port} baud={args.baud} n_len={n} seed={args.seed}")

    with SerialLink(args.port, baud=args.baud) as link:
        resp = link.ping()
        assert resp == RESP_PING, f"PING: expected 0xA5, got {resp:#x}"
        print("PING ok (0xA5)")

        for row in range(n):
            for cmd, mat, name in ((CMD_LOAD_Q, q, "Q"), (CMD_LOAD_K, k, "K"), (CMD_LOAD_V, v, "V")):
                resp = link.load_row(cmd, row, mat[row])
                assert resp == cmd, f"LOAD_{name} row {row}: echo mismatch, got {resp:#x}"
        print(f"loaded Q/K/V: {n} rows each")

        resp = link.set_nlen(n)
        assert resp == CMD_SET_NLEN, f"SET_NLEN: echo mismatch, got {resp:#x}"

        resp = link.run()
        assert resp == CMD_RUN, f"RUN: expected echo 0x52, got {resp:#x} (device busy?)"
        print("RUN accepted")

        while True:
            st = link.status()
            if st["done"]:
                assert not st["busy"], "STATUS: done latch set but busy also set"
                break
            time.sleep(0.01)
        print("STATUS: done")

        got = [link.read_out_row(row) for row in range(n)]
        expected = attn_model.attn_fixed(q, k, v, lut)
        mismatches = 0
        for row in range(n):
            for col in range(d):
                if got[row][col] != expected[row][col]:
                    mismatches += 1
                    print(f"MISMATCH row={row} col={col}: hw={got[row][col]} golden={expected[row][col]}")
        assert mismatches == 0, f"{mismatches} byte mismatches vs model/attn.py attn_fixed"
        print(f"READ_OUT matches model/attn.py attn_fixed bit-exactly ({n}x{d} bytes)")

        cycles = link.read_cycles()
        nblk = n // 4
        expected_cycles = nblk * (16 * nblk + 156) + 1
        assert cycles == expected_cycles, (
            f"READ_CYCLES={cycles} != formula nblk*(16*nblk+156)+1={expected_cycles}"
        )
        print(f"READ_CYCLES={cycles} matches formula nblk*(16*nblk+156)+1")

    print("attn_host: self-checking hardware test PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
