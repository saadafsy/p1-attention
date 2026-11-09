"""cocotb testbench for attn_uart_top: runs the byte protocol of
docs/phase6_fpga_guide.md 6.3.4 end to end against model/attn.py attn_fixed.
Frames are built/parsed by the shipped fpga/host/attn_host.py; only the 8N1
pin bit-banging (UartTbLink) is local. Tests run in declaration order.
"""

import pathlib
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "fpga" / "host"))
sys.path.insert(0, str(ROOT / "model"))
import attn as attn_model  # noqa: E402
import attn_host  # noqa: E402

LUT = attn_model.gen_exp_lut()
D = attn_model.D_DIM

# Must match the Makefile -G overrides; 16 clocks/bit is the RTL minimum.
CLK_HZ = 1_600_000
BAUD = 100_000
CLKS_PER_BIT = CLK_HZ // BAUD
assert CLKS_PER_BIT == 16, "test CLK_HZ/BAUD must match the Makefile -G overrides"
CLK_PERIOD_NS = 1_000_000_000.0 / CLK_HZ

REQUIRED_COMMANDS = {
    "PING", "LOAD_Q", "LOAD_K", "LOAD_V", "SET_NLEN", "RUN",
    "STATUS", "READ_OUT", "READ_CYCLES", "NAK_UNKNOWN", "NAK_BUSY", "RESYNC",
    "NAK_LOAD_BUSY", "NAK_NLEN_INVALID", "NAK_READ_BUSY",
}
EXERCISED = set()  # shared across every test in this file

# One failed uart_rx attempt: start + 8 data cells + stop vote (guide 6.3.3).
_MID = CLKS_PER_BIT // 2
_STEP = max(CLKS_PER_BIT // 16, 1)
FAILED_ATTEMPT_CYCLES = 9 * CLKS_PER_BIT + (_MID + _STEP + 1)


def seeded_rng():
    """RNG seeded from cocotb.RANDOM_SEED."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1
    return random.Random(seed)


def cycle_formula(n_len):
    """Cycle count closed form, docs/uarch.md 8.3."""
    nblk = n_len // 4
    return nblk * (16 * nblk + 156) + 1


def golden(q, k, v):
    return attn_model.attn_fixed(q, k, v, LUT)


def random_qkv(rng, n, d=D):
    q = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    v = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    return q, k, v


# ---- Physical-layer bit-banger (TB only) ----
class UartTbLink:
    """8N1 bit-banger on the DUT's uart_rx/uart_tx pins (stands in for
    pyserial, which has no simulated serial port)."""

    def __init__(self, dut, clks_per_bit=CLKS_PER_BIT):
        self.dut = dut
        self.clks = clks_per_bit
        self.dut.uart_rx.value = 1  # idle high

    async def send_byte(self, byte):
        bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1]  # start,d0..d7,stop
        for b in bits:
            self.dut.uart_rx.value = b
            for _ in range(self.clks):
                await RisingEdge(self.dut.clk)

    async def send_bytes(self, data):
        for b in data:
            await self.send_byte(b)

    async def drive_line_low(self, cycles):
        """Hold uart_rx low for `cycles` clocks, then release to idle-high."""
        self.dut.uart_rx.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)
        self.dut.uart_rx.value = 1

    def start_monitor(self):
        """Receive in a background task, so bytes sent while we drive uart_rx are not missed."""
        captured = []

        async def _run():
            while True:
                captured.append(await self.recv_byte())

        task = cocotb.start_soon(_run())
        return _RxMonitor(task, captured)

    async def recv_byte(self):
        """Wait for the start edge on uart_tx, then sample each bit cell, LSB first."""
        prev = 1
        while True:
            await FallingEdge(self.dut.clk)
            cur = int(self.dut.uart_tx.value)
            if prev == 1 and cur == 0:
                break
            prev = cur
        value = 0
        for i in range(8):
            for _ in range(self.clks):
                await FallingEdge(self.dut.clk)
            value |= int(self.dut.uart_tx.value) << i
        for _ in range(self.clks):
            await FallingEdge(self.dut.clk)
        stop = int(self.dut.uart_tx.value)
        assert stop == 1, "UartTbLink.recv_byte: bad stop bit (framing error on tx)"
        return value

    async def recv_bytes(self, n):
        return bytes([await self.recv_byte() for _ in range(n)])


class _RxMonitor:
    """Handle for a start_monitor() task: `captured` grows live; stop()
    cancels the task and returns the bytes seen."""

    def __init__(self, task, captured):
        self._task = task
        self.captured = captured

    def stop(self):
        self._task.cancel()
        return bytes(self.captured)


async def wait_until_quiet(dut, monitor, quiet_cycles, max_checks=200):
    """Stop the monitor once no byte arrives for `quiet_cycles` clocks;
    `quiet_cycles` must exceed the longest gap before the first response."""
    for _ in range(max_checks):
        before = len(monitor.captured)
        for _ in range(quiet_cycles):
            await RisingEdge(dut.clk)
        if len(monitor.captured) == before:
            return monitor.stop()
    raise TimeoutError("wait_until_quiet: link never went quiet")


# ---- Command-level helpers: attn_host frame fns + EXERCISED bookkeeping ---
async def do_ping(link):
    await link.send_bytes(attn_host.build_ping())
    resp = await link.recv_byte()
    EXERCISED.add("PING")
    return resp


async def do_load_row(link, cmd_name, cmd_byte, row, data16):
    frame = attn_host.build_load_row(cmd_byte, row, data16)
    await link.send_bytes(frame)
    resp = await link.recv_byte()
    EXERCISED.add(cmd_name)
    return resp


async def do_set_nlen(link, n):
    await link.send_bytes(attn_host.build_set_nlen(n))
    resp = await link.recv_byte()
    EXERCISED.add("SET_NLEN")
    return resp


async def do_run(link):
    await link.send_bytes(attn_host.build_run())
    resp = await link.recv_byte()
    EXERCISED.add("RUN")
    if attn_host.is_nak(resp):
        EXERCISED.add("NAK_BUSY")
    return resp


async def do_status(link):
    await link.send_bytes(attn_host.build_status())
    resp = await link.recv_byte()
    EXERCISED.add("STATUS")
    return attn_host.parse_status(resp)


async def do_read_out_row(link, row):
    await link.send_bytes(attn_host.build_read_out(row))
    data = await link.recv_bytes(16)
    EXERCISED.add("READ_OUT")
    return attn_host.decode_out_row(data)


async def do_read_cycles(link):
    await link.send_bytes(attn_host.build_read_cycles())
    data = await link.recv_bytes(4)
    EXERCISED.add("READ_CYCLES")
    return attn_host.decode_cycles(data)


async def do_resync(dut, link, quiet_cycles):
    """attn_host.SerialLink.resync() over the bit-banged link, drained by a monitor."""
    mon = link.start_monitor()
    await link.send_bytes(attn_host.build_resync_frame())
    tail = await wait_until_quiet(dut, mon, quiet_cycles)
    EXERCISED.add("RESYNC")
    return attn_host.is_resynced(tail), tail


async def do_load_busy_nak(link, cmd_byte, cmd_name):
    """Send only the LOAD command byte; while busy the DUT NAKs from P_CMD."""
    await link.send_byte(cmd_byte)
    resp = await link.recv_byte()
    EXERCISED.add(cmd_name)
    if attn_host.is_nak(resp):
        EXERCISED.add("NAK_LOAD_BUSY")
    return resp


async def do_unknown(link, byte):
    assert byte not in (
        attn_host.CMD_PING, attn_host.CMD_LOAD_Q, attn_host.CMD_LOAD_K,
        attn_host.CMD_LOAD_V, attn_host.CMD_SET_NLEN, attn_host.CMD_RUN,
        attn_host.CMD_STATUS, attn_host.CMD_READ_OUT, attn_host.CMD_READ_CYCLES,
    ), "do_unknown: byte must not collide with a real command"
    await link.send_byte(byte)
    resp = await link.recv_byte()
    if attn_host.is_nak(resp):
        EXERCISED.add("NAK_UNKNOWN")
    return resp


async def load_qkv(link, q, k, v):
    n = len(q)
    for row in range(n):
        for cmd_name, cmd_byte, mat in (
            ("LOAD_Q", attn_host.CMD_LOAD_Q, q),
            ("LOAD_K", attn_host.CMD_LOAD_K, k),
            ("LOAD_V", attn_host.CMD_LOAD_V, v),
        ):
            resp = await do_load_row(link, cmd_name, cmd_byte, row, mat[row])
            assert resp == cmd_byte, f"{cmd_name} row {row}: echo mismatch, got {resp:#x}"


async def run_and_wait_done(link, n_len, max_polls=500):
    resp = await do_set_nlen(link, n_len)
    assert resp == attn_host.CMD_SET_NLEN, f"SET_NLEN: echo mismatch, got {resp:#x}"

    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN, f"RUN: expected echo 0x52, got {resp:#x}"

    for _ in range(max_polls):
        st = await do_status(link)
        if st["done"]:
            assert not st["busy"], "STATUS: done latch set but busy also set"
            return
    raise TimeoutError(f"n_len={n_len}: STATUS never showed done within {max_polls} polls")


# ---- DUT bring-up ------------------------------------------------------------
async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.rst_btn.value = 1
    dut.uart_rx.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_btn.value = 0
    for _ in range(5):  # margin past sync2ff's 2-cycle reset release
        await RisingEdge(dut.clk)


# ---- Tests -------------------------------------------------------------------
@cocotb.test()
async def test_ping(dut):
    """PING (0x50) answers 0xA5."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, f"PING: expected 0xA5, got {resp:#x}"


@cocotb.test()
async def test_nak_unknown(dut):
    """Unknown command bytes get NAK 0x3F and a following PING still works."""
    await start_and_reset(dut)
    link = UartTbLink(dut)

    for bad in (0x00, 0xFF, 0x41, 0x3F):  # 0x3F: NAK itself is not a command
        resp = await do_unknown(link, bad)
        assert resp == attn_host.RESP_NAK, (
            f"unknown command {bad:#x}: expected NAK 0x3F, got {resp:#x}"
        )

    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, "PING after NAK must still work (no FSM desync)"


@cocotb.test()
async def test_end_to_end(dut):
    """Full host flow for n_len 4 and 16: outputs bit-exact vs golden, cycle count vs formula."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()

    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING

    for n in (4, 16):
        q, k, v = random_qkv(rng, n)
        await load_qkv(link, q, k, v)
        await run_and_wait_done(link, n)

        got = [await do_read_out_row(link, row) for row in range(n)]
        expected = golden(q, k, v)
        for row in range(n):
            for col in range(D):
                assert got[row][col] == expected[row][col], (
                    f"n={n} row={row} col={col}: uart={got[row][col]} "
                    f"golden={expected[row][col]}"
                )

        cyc = await do_read_cycles(link)
        exp_cyc = cycle_formula(n)
        assert cyc == exp_cyc, (
            f"n={n}: READ_CYCLES={cyc} != formula nblk*(16*nblk+156)+1={exp_cyc}"
        )
        dut._log.info(f"test_end_to_end: n={n} cycle_count={cyc} (formula {exp_cyc})")


@cocotb.test()
async def test_run_while_busy_nak(dut):
    """A second RUN while busy gets NAK; n_len=64 keeps the run long enough."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()
    n = 64
    q, k, v = random_qkv(rng, n)
    await load_qkv(link, q, k, v)

    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN

    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN, f"RUN: expected echo, got {resp:#x}"

    resp2 = await do_run(link)
    assert resp2 == attn_host.RESP_NAK, f"RUN-while-busy: expected NAK 0x3F, got {resp2:#x}"

    for _ in range(2000):
        st = await do_status(link)
        if st["done"]:
            break
    else:
        raise TimeoutError("test_run_while_busy_nak: run never completed")


@cocotb.test()
async def test_load_while_busy_nak(dut):
    """LOAD_Q while busy gets NAK, consumes no row byte (next PING answers),
    and does not corrupt the in-flight run's output."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()
    n = 64
    q, k, v = random_qkv(rng, n)
    await load_qkv(link, q, k, v)

    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN

    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN, f"RUN: expected echo, got {resp:#x}"

    st = await do_status(link)
    assert st["busy"], "test setup error: expected busy=1 right after RUN accepted"

    resp2 = await do_load_busy_nak(link, attn_host.CMD_LOAD_Q, "LOAD_Q")
    assert resp2 == attn_host.RESP_NAK, (
        f"LOAD_Q-while-busy: expected NAK 0x3F, got {resp2:#x}"
    )

    resp3 = await do_ping(link)
    assert resp3 == attn_host.RESP_PING, (
        f"PING immediately after LOAD_Q-while-busy NAK: expected 0xA5, got "
        f"{resp3:#x} (the FSM must have stayed in P_CMD, not swallowed this "
        "PING byte as a row index left over from a wrongly-accepted LOAD_Q)"
    )

    for _ in range(2000):
        st = await do_status(link)
        if st["done"]:
            assert not st["busy"], "STATUS: done latch set but busy also set"
            break
    else:
        raise TimeoutError("test_load_while_busy_nak: run never completed")

    got = [await do_read_out_row(link, row) for row in range(n)]
    expected = golden(q, k, v)
    for row in range(n):
        for col in range(D):
            assert got[row][col] == expected[row][col], (
                f"post-LOAD-while-busy run: row={row} col={col} "
                f"uart={got[row][col]} golden={expected[row][col]} "
                "(the rejected LOAD_Q attempt must not have corrupted the "
                "in-flight run's inputs)"
            )


@cocotb.test()
async def test_framing_error_resilience(dut):
    """A sub-bit glitch on uart_rx is a silent false start; a break spanning
    a retry yields one 0xFF byte and so one spurious NAK. PING works after both."""
    await start_and_reset(dut)
    link = UartTbLink(dut)

    # Worst gap: two failed-attempt windows plus one NAK byte, with margin.
    framing_quiet_cycles = 4 * FAILED_ATTEMPT_CYCLES

    # Scenario 1: released before the start vote's first sample (Mid-Step).
    mon = link.start_monitor()
    await link.drive_line_low(cycles=max(_MID - _STEP - 2, 1))
    tail = await wait_until_quiet(dut, mon, quiet_cycles=framing_quiet_cycles)
    assert tail == b"", (
        f"sub-bit-cell glitch (false start): expected total silence, got {tail!r}"
    )
    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, "PING after a silent false-start glitch must succeed"

    # Scenario 2: the retry ends mid-byte and reads as 0xFF, an unknown command.
    mon = link.start_monitor()
    await link.drive_line_low(cycles=11 * CLKS_PER_BIT)
    tail = await wait_until_quiet(dut, mon, quiet_cycles=framing_quiet_cycles)
    assert tail == bytes([attn_host.RESP_NAK]), (
        f"break spanning a retry ({FAILED_ATTEMPT_CYCLES}-clock attempt window): "
        f"expected exactly one spurious NAK 0x3F, got {tail!r}"
    )

    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, (
        "PING after a break-triggered spurious NAK must still succeed "
        "(the protocol FSM itself never desyncs, only the transport layer glitched)"
    )


@cocotb.test()
async def test_reset_mid_operation(dut):
    """rst_btn mid-run and mid-UART-byte; each followed by a full reload,
    run and readback (RAMs have no reset)."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()

    # ---- Scenario 1: mid-run reset, UART line idle ----
    n = 16
    q, k, v = random_qkv(rng, n)
    await load_qkv(link, q, k, v)

    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN
    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN

    # n=16 runs 881 clocks, so 200 lands mid-run.
    for _ in range(200):
        await RisingEdge(dut.clk)

    dut.rst_btn.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_btn.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)

    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, "PING after mid-run reset must succeed"

    st = await do_status(link)
    assert not st["busy"] and not st["done"], (
        f"STATUS immediately after reset must read idle/no-done, got {st}"
    )

    q2, k2, v2 = random_qkv(rng, n)
    await load_qkv(link, q2, k2, v2)
    await run_and_wait_done(link, n)

    got = [await do_read_out_row(link, row) for row in range(n)]
    expected = golden(q2, k2, v2)
    for row in range(n):
        for col in range(D):
            assert got[row][col] == expected[row][col], (
                f"post-reset (scenario 1) run: row={row} col={col} "
                f"uart={got[row][col]} golden={expected[row][col]}"
            )

    # ---- Scenario 2: reset mid-UART-byte ----
    n3 = 8
    q3, k3, v3 = random_qkv(rng, n3)
    frame = attn_host.build_load_row(attn_host.CMD_LOAD_Q, 0, q3[0])
    first_byte = frame[0]
    bits = [0] + [(first_byte >> i) & 1 for i in range(8)] + [1]  # start,d0..d7,stop

    # Start bit + 2 data bits, then reset with the byte in flight.
    for b in bits[:3]:
        dut.uart_rx.value = b
        for _ in range(CLKS_PER_BIT):
            await RisingEdge(dut.clk)

    dut.rst_btn.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_btn.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.uart_rx.value = 1  # abandon the in-flight byte

    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, "PING after mid-byte reset must succeed"

    await load_qkv(link, q3, k3, v3)
    await run_and_wait_done(link, n3)

    got = [await do_read_out_row(link, row) for row in range(n3)]
    expected = golden(q3, k3, v3)
    for row in range(n3):
        for col in range(D):
            assert got[row][col] == expected[row][col], (
                f"post-reset (scenario 2, mid-byte) run: row={row} col={col} "
                f"uart={got[row][col]} golden={expected[row][col]}"
            )


@cocotb.test()
async def test_resync_after_desync(dut):
    """Abandon a LOAD_Q frame mid-payload, resync, then a full reload, run
    and readback must match golden (pings are eaten as payload, so reload all)."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()
    n = 8
    q, k, v = random_qkv(rng, n)

    partial = attn_host.build_load_row(attn_host.CMD_LOAD_Q, 0, q[0])[:2 + 8]
    await link.send_bytes(partial)

    # Monitor runs during the burst, so one byte period plus margin suffices.
    ok, tail = await do_resync(dut, link, quiet_cycles=10 * CLKS_PER_BIT)
    assert ok, f"resync: expected the drained tail to end in 0xA5, got {tail!r}"

    await load_qkv(link, q, k, v)
    await run_and_wait_done(link, n)

    got = [await do_read_out_row(link, row) for row in range(n)]
    expected = golden(q, k, v)
    for row in range(n):
        for col in range(D):
            assert got[row][col] == expected[row][col], (
                f"post-resync run: row={row} col={col} uart={got[row][col]} "
                f"golden={expected[row][col]}"
            )


@cocotb.test()
async def test_set_nlen_invalid_nak(dut):
    """SET_NLEN outside {4,8,..,64} is NAKed and leaves the stored n_len (checked via cycle count)."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()
    n = 8
    q, k, v = random_qkv(rng, n)
    await load_qkv(link, q, k, v)

    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN

    for bad in (0, 2, 6, 65, 68, 127, 0x84, 0xFF):
        await link.send_bytes(attn_host.build_set_nlen(bad))
        resp = await link.recv_byte()
        EXERCISED.add("SET_NLEN")
        assert resp == attn_host.RESP_NAK, (
            f"SET_NLEN {bad:#x}: expected NAK 0x3F, got {resp:#x}"
        )
        EXERCISED.add("NAK_NLEN_INVALID")

    for good in (4, 64):
        resp = await do_set_nlen(link, good)
        assert resp == attn_host.CMD_SET_NLEN, f"SET_NLEN {good}: expected echo, got {resp:#x}"
    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN

    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN
    for _ in range(500):
        st = await do_status(link)
        if st["done"]:
            break
    else:
        raise TimeoutError("test_set_nlen_invalid_nak: run never completed")

    cyc = await do_read_cycles(link)
    assert cyc == cycle_formula(n), (
        f"stored n_len was corrupted by an invalid SET_NLEN: cycles={cyc} != {cycle_formula(n)}"
    )
    got = [await do_read_out_row(link, row) for row in range(n)]
    expected = golden(q, k, v)
    for row in range(n):
        for col in range(D):
            assert got[row][col] == expected[row][col], (
                f"post-invalid-SET_NLEN run: row={row} col={col} uart={got[row][col]} "
                f"golden={expected[row][col]}"
            )


@cocotb.test()
async def test_read_while_busy_nak(dut):
    """READ_OUT and READ_CYCLES while busy get NAK without consuming a row
    byte; after the run both match golden."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()
    n = 64
    q, k, v = random_qkv(rng, n)
    await load_qkv(link, q, k, v)
    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN
    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN
    st = await do_status(link)
    assert st["busy"], "test setup error: expected busy=1 right after RUN accepted"

    # Command byte only, no row byte.
    await link.send_byte(attn_host.CMD_READ_OUT)
    resp = await link.recv_byte()
    assert resp == attn_host.RESP_NAK, f"READ_OUT-while-busy: expected NAK, got {resp:#x}"
    EXERCISED.add("NAK_READ_BUSY")
    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, "PING after READ_OUT NAK must succeed (no row byte consumed)"

    await link.send_bytes(attn_host.build_read_cycles())
    resp = await link.recv_byte()
    assert resp == attn_host.RESP_NAK, f"READ_CYCLES-while-busy: expected NAK, got {resp:#x}"
    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING

    for _ in range(2000):
        st = await do_status(link)
        if st["done"]:
            assert not st["busy"]
            break
    else:
        raise TimeoutError("test_read_while_busy_nak: run never completed")

    cyc = await do_read_cycles(link)
    assert cyc == cycle_formula(n)
    got = [await do_read_out_row(link, row) for row in range(n)]
    expected = golden(q, k, v)
    for row in range(n):
        for col in range(D):
            assert got[row][col] == expected[row][col], (
                f"post-busy-NAK readback: row={row} col={col} uart={got[row][col]} "
                f"golden={expected[row][col]}"
            )


@cocotb.test()
async def test_zz_coverage_closure(dut):
    """Must stay the last test: fails if any command class was never exercised."""
    missing = REQUIRED_COMMANDS - EXERCISED
    assert not missing, f"protocol command classes never exercised: {sorted(missing)}"
    dut._log.info(f"coverage closure: exercised {sorted(EXERCISED)}")
