#!/usr/bin/env python3
"""attn_host: the Phase 6 bring-up kit host script (docs/phase6_fpga_guide.md
section 6.3, byte protocol NORMATIVE at 6.3.4). Runs one self-checking
attention inference over the UART link and asserts equality against
model/attn.py attn_fixed. That comparison IS the hardware test the guide
promises (guide 6.2/6.3.4 "Host flow for one inference").

Structure (deliberate, so tb/fpga_uart can import the wire-level logic
without needing pyserial or a board):
  - Module-level constants and pure encode/decode functions: frame builders
    (build_*) and parsers (parse_status, decode_out_row, decode_cycles,
    is_nak) that take/return plain bytes. No I/O, no pyserial, importable
    anywhere.
  - SerialLink: a thin class wrapping pyserial for the physical transport.
    `import serial` is INSIDE __init__ (lazy), not at module scope, so this
    module imports cleanly on a machine without pyserial installed (the
    cocotb testbench does exactly that: it imports the frame functions and
    never instantiates SerialLink).
  - main(): loads random Q/K/V over the link, runs, reads back, and asserts
    bit-exact equality against model/attn.py attn_fixed. --selftest exercises
    every encode/decode round trip offline (no device, no pyserial import).

All multi-byte protocol quantities are little-endian (guide 6.3.4). Q/K/V/
output data bytes are ACT Q1.6 two's-complement codes (docs/uarch.md 3.1):
the SAME raw int8 codes model/attn.py attn_fixed consumes and returns
directly, so no float conversion happens anywhere in this script.
"""

import argparse
import random
import sys
import time
from pathlib import Path

# ---- Protocol constants (NORMATIVE: docs/phase6_fpga_guide.md 6.3.4) -------
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
RESP_NAK = 0x3F  # '?'; never a legal command byte, so it can never be
# mistaken for an echo (guide 6.3.4).

LOAD_CMDS = (CMD_LOAD_Q, CMD_LOAD_K, CMD_LOAD_V)
ROW_BYTES = 16  # one Q/K/V/output row payload, uarch.md 8.3


# ---- ACT Q1.6 byte <-> signed int8 code (guide 6.3.4, uarch.md 3.1) --------
def to_u8(v):
    """Signed int in [-128, 127] (an ACT Q1.6 code) -> unsigned wire byte."""
    if not (-128 <= v <= 127):
        raise ValueError(f"ACT code out of range: {v}")
    return v & 0xFF


def from_u8(v):
    """Unsigned wire byte -> signed int8 (an ACT Q1.6 code)."""
    v &= 0xFF
    return v - 256 if v >= 128 else v


# ---- Pure frame builders (bytes out, no I/O) -------------------------------
def build_ping():
    return bytes([CMD_PING])


def build_load_row(cmd, row, data16):
    """cmd in {CMD_LOAD_Q, CMD_LOAD_K, CMD_LOAD_V}; row in [0, 63] (only the
    low 6 bits are used on the wire, guide 6.3.4); data16 is 16 signed ACT
    codes, column 0 first."""
    if cmd not in LOAD_CMDS:
        raise ValueError(f"build_load_row: not a LOAD_* command: {cmd:#x}")
    if len(data16) != ROW_BYTES:
        raise ValueError(f"build_load_row: need {ROW_BYTES} data bytes, got {len(data16)}")
    return bytes([cmd, row & 0x3F] + [to_u8(v) for v in data16])


def build_set_nlen(n_len):
    """n_len byte; the low 7 bits are stored (guide 6.3.4). The contract
    (multiple of 4 in [4, 64]) is NOT validated here (the device does not
    validate it either); building an out-of-contract frame is legal, the
    device's behavior is simply undefined, exactly as in simulation."""
    return bytes([CMD_SET_NLEN, n_len & 0x7F])


def build_run():
    return bytes([CMD_RUN])


def build_status():
    return bytes([CMD_STATUS])


def build_read_out(row):
    return bytes([CMD_READ_OUT, row & 0x3F])


def build_read_cycles():
    return bytes([CMD_READ_CYCLES])


# ---- Pure response parsers (bytes/int in, Python values out) --------------
def is_nak(resp_byte):
    return resp_byte == RESP_NAK


def parse_status(status_byte):
    """Status byte (guide 6.3.4): bit0 busy, bit1 done latch, bits 7:2 zero."""
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
    """4 little-endian wire bytes -> unsigned cycle_count (guide 6.3.4)."""
    if len(data) != 4:
        raise ValueError(f"decode_cycles: need 4 bytes, got {len(data)}")
    return int.from_bytes(data, byteorder="little", signed=False)


# ---- Pure drain / resync logic (bytes/callables in, plain values out) -----
# Auditor finding (guide 6.3.4): a framing-error break long enough to span
# more than one uart_rx retry attempt can produce a LEGITIMATE (framing-
# valid) phantom byte once the line returns to idle mid-attempt -- typically
# all-1s, an unknown command, so the device transmits an UNSOLICITED NAK
# (0x3F) nobody asked for. Real USB-UART bridges can do exactly this with a
# BREAK condition on port open/close. drain_bytes below is the pure loop
# both SerialLink (on connect, and inside resync) use to flush that kind of
# stale/unsolicited data before trusting the link.
def drain_bytes(read_fn, chunk_size=256):
    """Repeatedly call read_fn(chunk_size) -> bytes (any bytes-like, short
    reads allowed) until it returns nothing, concatenating everything read.
    A plain function of a read callable (not a socket/serial object) so it
    is exercised offline in --selftest without pyserial: the TB's own
    UartTbLink.drain-style helpers mirror this same loop shape against the
    bit-banged link (see tb/fpga_uart/test_fpga_uart.py)."""
    drained = bytearray()
    while True:
        chunk = read_fn(chunk_size)
        if not chunk:
            break
        drained.extend(chunk)
    return bytes(drained)


RESYNC_PING_COUNT = 18  # covers the longest possible in-flight payload: row
# + 16 data bytes + one command byte (guide 6.3.4).


def build_resync_frame():
    """18 PING bytes (guide 6.3.4 resync procedure). Sending this many pings
    guarantees the device is back in P_CMD and has processed at least one
    genuine PING by the time they are all consumed, whatever multi-byte
    command (if any) was abandoned in flight."""
    return build_ping() * RESYNC_PING_COUNT


def is_resynced(drained_tail):
    """Pure check on the bytes drained (with a timeout, until quiet) after
    sending build_resync_frame(): resync succeeds ONLY if the LAST byte seen
    is 0xA5. Checking only "does 0xA5 appear anywhere" (the guide's original,
    buggy wording) is wrong: an in-flight multi-byte command can still be
    mid-flight when the pings start, so the drain can see an echo of that
    abandoned command followed by several more 0xA5 echoes from pings that
    landed as fresh commands afterward (up to ~11 of them for an 18-ping
    burst against a maximally-desynced LOAD_Q/K/V). Stopping at the first
    0xA5 leaves the link still desynced. Requiring the LAST drained byte to
    be 0xA5, after a full drain-until-quiet, is the corrected procedure."""
    return len(drained_tail) > 0 and drained_tail[-1] == RESP_PING


# ---- Thin serial transport (pyserial imported lazily, INSIDE __init__) ----
class SerialLink:
    """Wraps pyserial for the 8N1 physical transport described in guide
    6.3.3. All protocol framing lives in the pure functions above; this
    class only moves bytes and provides one convenience method per command
    so main() reads as the host flow from guide 6.3.4."""

    def __init__(self, port, baud=115200, timeout=2.0, drain_timeout=0.05):
        import serial  # lazy: this module must import without pyserial

        # Connect with a SHORT read timeout first, purely to drain any bytes
        # already sitting in the RX buffer (e.g. a BREAK artifact some
        # USB-UART bridges emit on port open/close, guide 6.3.4) before the
        # real protocol timeout takes over. Without this, a stale byte can
        # offset every subsequent response by one.
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

    # One convenience method per protocol command (guide 6.3.4 table).
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
        self.write(build_read_out(row))
        return decode_out_row(self.read(ROW_BYTES))

    def read_cycles(self):
        self.write(build_read_cycles())
        return decode_cycles(self.read(4))

    def resync(self, settle_timeout=0.5):
        """guide 6.3.4 resync procedure, CORRECTED: send 18 pings, then
        drain every response with a timeout until the line goes quiet (real
        hardware's RX is continuously live in the background regardless of
        what this call is doing, so nothing is missed by draining
        afterward, unlike the TB's simulation-only concurrency concern --
        see tb/fpga_uart/test_fpga_uart.py's do_resync). Declares success
        only if the LAST byte drained is 0xA5 (see is_resynced).

        WARNING, unconditionally: the pings themselves may have been
        consumed as payload of whatever command was in flight (0x50 is a
        legal row byte and a legal ACT data code), corrupting any rows
        already loaded. Callers MUST reload every Q/K/V row after calling
        this, whether or not it returns True quickly -- resync only
        recovers the COMMAND stream, never the data that was mid-load when
        the desync happened."""
        self.write(build_resync_frame())
        old_timeout = self._ser.timeout
        self._ser.timeout = settle_timeout
        try:
            tail = drain_bytes(lambda n: self._ser.read(n))
        finally:
            self._ser.timeout = old_timeout
        return is_resynced(tail)


# ---- Offline self-test: every encode/decode round trip, no hardware -------
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
    # low-7-bits-only wrap: an out-of-range byte still encodes deterministically
    assert build_set_nlen(0x81) == bytes([CMD_SET_NLEN, 0x01])
    assert build_run() == bytes([CMD_RUN])
    assert build_status() == bytes([CMD_STATUS])
    assert build_read_out(3) == bytes([CMD_READ_OUT, 3])
    assert build_read_out(0x40) == bytes([CMD_READ_OUT, 0x00])  # low 6 bits only
    assert build_read_cycles() == bytes([CMD_READ_CYCLES])

    assert parse_status(0b00) == {"busy": False, "done": False}
    assert parse_status(0b01) == {"busy": True, "done": False}
    assert parse_status(0b10) == {"busy": False, "done": True}
    assert parse_status(0b11) == {"busy": True, "done": True}
    # bits 7:2 must be ignored, not corrupt the parse (0xFE: bit1=1, bit0=0)
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

    # drain_bytes: pure loop over a fake read_fn, no pyserial/socket needed.
    canned = [b"\xa5\x3f", b"more", b""]  # two non-empty reads, then quiet

    def fake_read(_n):
        return canned.pop(0) if canned else b""

    assert drain_bytes(fake_read) == b"\xa5\x3fmore"

    def fake_read_already_quiet(_n):
        return b""

    assert drain_bytes(fake_read_already_quiet) == b""

    # resync: frame shape and the corrected last-byte-must-be-0xA5 check.
    frame = build_resync_frame()
    assert len(frame) == RESYNC_PING_COUNT == 18
    assert set(frame) == {CMD_PING}

    assert not is_resynced(b"")  # nothing drained: link never settled
    assert not is_resynced(bytes([RESP_PING, RESP_NAK]))  # trailing byte wrong
    assert is_resynced(bytes([RESP_PING]))
    # the documented worst case: one stray echo of an abandoned multi-byte
    # command, then several 0xA5 echoes from pings that landed as fresh
    # commands -- must still resync on the trailing 0xA5.
    assert is_resynced(bytes([CMD_LOAD_Q, RESP_PING, RESP_PING, RESP_PING]))
    # stopping at the FIRST 0xA5 (the guide's original, buggy wording) would
    # have wrongly declared success here too soon; the corrected check only
    # cares about the LAST byte, which this case also satisfies -- the real
    # bug that check fixes is caught above (0xA5 not last).

    print("attn_host --selftest: all encode/decode round trips PASS")


# ---- main(): the self-checking hardware test (guide 6.2/6.3.4) ------------
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

    # Golden model import: repo_root/model, deferred to here so --selftest
    # never needs it either.
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
        expected_cycles = nblk * (16 * nblk + 156) + 1  # docs/uarch.md 8.3 closed form
        assert cycles == expected_cycles, (
            f"READ_CYCLES={cycles} != formula nblk*(16*nblk+156)+1={expected_cycles}"
        )
        print(f"READ_CYCLES={cycles} matches formula nblk*(16*nblk+156)+1")

    print("attn_host: self-checking hardware test PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
