"""cocotb testbench for attn_uart_top (Phase 6 bring-up kit). Verifies the
byte protocol NORMATIVE at docs/phase6_fpga_guide.md 6.3.4 end to end against
attention_top's own golden reference, model/attn.py attn_fixed.

This testbench does NOT reimplement the wire protocol: it imports the pure
frame builder/parser functions (build_ping, build_load_row, build_set_nlen,
build_run, build_status, build_read_out, build_read_cycles, build_resync_frame,
parse_status, decode_out_row, decode_cycles, is_nak, is_resynced) directly
from fpga/host/attn_host.py, so the exact code the user will run at the bench
is what gets exercised here. Only the PHYSICAL bit-banging of the 8N1 line
(something pyserial does for the real host, and a real OS serial port has no
simulation equivalent) is implemented locally, in UartTbLink below; it
drives/samples ONLY the DUT's uart_rx input pin and uart_tx output pin, plus
clk/rst_btn -- never anything inside attn_uart_top or attention_top.

CLK_HZ/BAUD: overridden by the Makefile to 1_600_000 / 100_000
(ClksPerBit = 16, the minimum the uart_rx/uart_tx elaboration-time check
allows, guide 6.3.3) purely to keep sim time sane; see the Makefile comment.
The clock PERIOD driven from Python must correspond to that same CLK_HZ
(625 ns), or the simulated "clocks per bit" the RTL divider actually uses
would not match ClksPerBit here.

No verilator --coverage in this directory (Makefile comment): instead, a
simple set-based check (test_zz_coverage_closure, the LAST test in this
file) fails loudly if any protocol command class was never exercised across
the whole regression. cocotb's RegressionManager registers tests in module
declaration order (vars(mod) preserves insertion order; start_regression
only stable-sorts by `stage`, which defaults equal for all tests here), so
declaring the closure check last in this file is sufficient for it to see
everything the earlier tests recorded into the module-level EXERCISED set.

Concurrency note (auditor finding, framing/resync tests): a plain "write a
burst, then recv_byte() once" pattern MISSES anything the DUT transmits
WHILE this TB's own coroutine is still busy driving uart_rx (this Python
coroutine cannot listen and drive at the same time). Real hardware has no
such gap -- pyserial's OS-buffered RX is continuously live in the background
regardless of what the host's write() is doing -- so this is a
simulation-only concern, handled here by UartTbLink.start_monitor(), a
background cocotb Task that keeps receiving bytes while the foreground
coroutine does something else.

Seed plumbing: same house style as tb/attention_top -- every RNG is built
from cocotb.RANDOM_SEED via seeded_rng(), so SEED=1 vs SEED=7 provably
changes stimulus.
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
import attn_host  # noqa: E402  (the SHIPPED host script; frame fns imported)

LUT = attn_model.gen_exp_lut()
D = attn_model.D_DIM  # 16, docs/uarch.md section 1

CLK_HZ = 1_600_000
BAUD = 100_000
CLKS_PER_BIT = CLK_HZ // BAUD  # 16, matches the Makefile -G overrides
assert CLKS_PER_BIT == 16, "test CLK_HZ/BAUD must match the Makefile -G overrides"
CLK_PERIOD_NS = 1_000_000_000.0 / CLK_HZ  # 625.0 ns

REQUIRED_COMMANDS = {
    "PING", "LOAD_Q", "LOAD_K", "LOAD_V", "SET_NLEN", "RUN",
    "STATUS", "READ_OUT", "READ_CYCLES", "NAK_UNKNOWN", "NAK_BUSY", "RESYNC",
    "NAK_LOAD_BUSY",
}
EXERCISED = set()  # module-level: shared across every test in this file

# One failed uart_rx receive attempt (guide 6.3.3): start(clks) + 8 data
# cells(clks) + stop-vote cells (Mid+Step+1), all at ClksPerBit granularity.
# Used to size the break/silence stimuli in test_framing_error_resilience.
_MID = CLKS_PER_BIT // 2
_STEP = max(CLKS_PER_BIT // 16, 1)
FAILED_ATTEMPT_CYCLES = 9 * CLKS_PER_BIT + (_MID + _STEP + 1)


def seeded_rng():
    """Build an RNG from cocotb's per-test seed (house style, see
    tb/matmul_tile/test_matmul_tile.py docstring for the full rationale)."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1  # defensive fallback only; COCOTB_RANDOM_SEED is always set
    return random.Random(seed)


def cycle_formula(n_len):
    """docs/uarch.md 8.3, same closed form as tb/attention_top."""
    nblk = n_len // 4
    return nblk * (16 * nblk + 156) + 1


def golden(q, k, v):
    return attn_model.attn_fixed(q, k, v, LUT)


def random_qkv(rng, n, d=D):
    q = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    v = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
    return q, k, v


# ---- Physical-layer bit-banger (TB-only; NOT part of the shipped host) ----
class UartTbLink:
    """Drives/samples ONLY the DUT's uart_rx/uart_tx pins, 8N1, ClksPerBit
    clocks per bit cell (same framing fpga/uart_rx.sv and fpga/uart_tx.sv
    implement, guide 6.3.3). This class exists only because a cocotb sim has
    no real OS serial port for pyserial to open; the actual protocol framing
    for every command below comes from the imported attn_host functions."""

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
        """Raw wire-level stimulus: hold uart_rx low for `cycles` clocks,
        then release to idle-high. No framing assumed at this layer -- used
        to build both a sub-bit-cell glitch (false start, guide 6.3.3: "a
        false start returns to idle and emits nothing") and a break that
        outlasts a full failed-attempt window (guide 6.3.3: "the receiver
        returns to idle right after the stop vote" and, seeing rx still
        low, immediately starts ANOTHER attempt) -- see
        test_framing_error_resilience for both cases and why each duration
        was chosen."""
        self.dut.uart_rx.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)
        self.dut.uart_rx.value = 1

    def start_monitor(self):
        """Fork a background task that continuously calls recv_byte() into
        a growing list, so nothing transmitted while THIS coroutine is
        still driving uart_rx (a break, a resync burst) is missed. See the
        module docstring's concurrency note."""
        captured = []

        async def _run():
            while True:
                captured.append(await self.recv_byte())

        task = cocotb.start_soon(_run())
        return _RxMonitor(task, captured)

    async def recv_byte(self):
        """Detect the start-bit falling edge on uart_tx, then sample the
        middle of each subsequent ClksPerBit-wide cell (data LSB first,
        matching fpga/uart_tx.sv's {stop, data, start} shift order)."""
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
    """Handle for a UartTbLink.start_monitor() background task: `captured`
    grows live as bytes arrive; stop() kills the task and returns everything
    seen so far. Real hardware needs no equivalent (see module docstring):
    this exists only because a cocotb coroutine cannot listen and drive the
    same simulated wire at once."""

    def __init__(self, task, captured):
        self._task = task
        self.captured = captured

    def stop(self):
        self._task.cancel()
        return bytes(self.captured)


async def wait_until_quiet(dut, monitor, quiet_cycles, max_checks=200):
    """Poll monitor.captured until no new byte has arrived for
    `quiet_cycles` clocks in a row, then stop the monitor and return
    everything captured. `quiet_cycles` must exceed the LONGEST possible gap
    before any response can appear at all (not just one byte period): if the
    monitor was started before a multi-cycle stimulus/pipeline delay that
    produces no bytes for a while, too short a window here declares "quiet"
    before the first byte has even had a chance to arrive. Callers size this
    per scenario; see the call sites for the actual gap being bounded."""
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
    """TB-side equivalent of attn_host.SerialLink.resync(): sends the
    IMPORTED build_resync_frame(), drains everything the DUT transmits
    (via a background monitor -- responses can start arriving before all
    18 ping bytes are even sent, see the module docstring's concurrency
    note) until quiet, and checks success with the IMPORTED is_resynced()
    pure function -- exactly the logic the shipped host uses, just over the
    bit-banged link instead of pyserial."""
    mon = link.start_monitor()
    await link.send_bytes(attn_host.build_resync_frame())
    tail = await wait_until_quiet(dut, mon, quiet_cycles)
    EXERCISED.add("RESYNC")
    return attn_host.is_resynced(tail), tail


async def do_load_busy_nak(link, cmd_byte, cmd_name):
    """Send ONLY the LOAD_Q/K/V command byte (deliberately no row byte, no
    payload): while attn_busy is set, attn_uart_top NAKs immediately from
    P_CMD and never transitions to P_LROW/P_LDATA (guide 6.3.4, mirrors the
    RUN-while-busy arm), so nothing else should ever be sent as part of this
    frame. Callers prove that by sending a real command right after and
    checking it is not mistaken for a row/payload byte."""
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
    for _ in range(5):  # margin past sync2ff's 2-cycle rst release latency
        await RisingEdge(dut.clk)


# ---- Tests -------------------------------------------------------------------
@cocotb.test()
async def test_ping(dut):
    """PING (0x50) must echo 0xA5, link test, no state change."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, f"PING: expected 0xA5, got {resp:#x}"


@cocotb.test()
async def test_nak_unknown(dut):
    """An unknown command byte gets NAK 0x3F, and the FSM stays in P_CMD
    (checked by a following PING succeeding normally, no desync)."""
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
    """Full LOAD_Q/K/V + SET_NLEN + RUN + poll STATUS + READ_OUT +
    READ_CYCLES flow for n_len in {4, 16}, random data, bit-exact compare
    against model/attn.py attn_fixed EVERY byte, plus the cycle_count
    formula check (guide 6.3.4 "Host flow for one inference")."""
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
    """A second RUN sent while attention_top is still busy must NAK (0x3F)
    and must NOT restart the pulse (guide 6.3.4). Uses n_len=64 (nblk=16,
    6593 core clocks, ~4.1 ms sim time) so the two-command round trip has
    enormous margin against the run finishing early."""
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

    # Drain to completion so the DUT is idle for whatever runs next.
    for _ in range(2000):
        st = await do_status(link)
        if st["done"]:
            break
    else:
        raise TimeoutError("test_run_while_busy_nak: run never completed")


@cocotb.test()
async def test_load_while_busy_nak(dut):
    """LOAD_Q/K/V sent while attention_top is busy must NAK (0x3F)
    immediately at the command byte and consume NO row/payload bytes (guide
    6.3.4, mirrors the RUN-while-busy arm; rtl-designer fix under review).
    Proven three ways: (1) the response to the bare LOAD_Q command byte is
    exactly 0x3F; (2) a PING sent immediately afterward gets a clean 0xA5,
    which is only possible if the FSM stayed in P_CMD and did NOT swallow
    the PING byte as a row index (had the NAK path wrongly fallen through
    to P_LROW, the PING's 0x50 would have been consumed as a row byte
    instead of interpreted as a command, and this PING would silently hang
    waiting for 16 more data bytes that never come); (3) after the run
    completes, READ_OUT matches model/attn.py attn_fixed bit-exactly,
    proving the load attempt did not corrupt the in-flight run's inputs
    either. Uses n_len=64 (nblk=16, 6593 core clocks, ~4.1 ms sim time),
    the same setup as test_run_while_busy_nak, for enormous margin against
    the run finishing before this multi-step check completes; STATUS is
    also polled first to positively confirm busy=1 before proceeding."""
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
    """A low glitch on uart_rx behaves in one of TWO genuinely different
    ways, both real bench symptoms, both checked here by MONITORING uart_tx
    for the whole window rather than assuming what did or did not happen
    (guide 6.3.3/6.3.4, auditor finding: the original version of this test
    silently swallowed a spurious response inside an unmonitored dead
    window and asserted a false claim):

    1. Sub-bit-cell glitch (shorter than the start-bit vote's own sample
       window): a FALSE START (guide 6.3.3, "a false start returns to idle
       and emits nothing"). Genuinely nothing is ever transmitted -- proven
       here by monitoring, not assumed.
    2. A break that OUTLASTS one full failed-attempt window (guide 6.3.3:
       start + 8 data cells + stop vote, FAILED_ATTEMPT_CYCLES clocks at
       this ClksPerBit): uart_rx's own stop vote fails and correctly drops
       the first attempt (a genuine framing error), but seeing rx still
       low, immediately starts a SECOND attempt (guide 6.3.3: "the receiver
       returns to idle right after the stop vote"). If the break ends
       mid-way through that second attempt, most of its data/stop cells
       read idle-high, which uart_rx reads as a LEGITIMATE, framing-valid
       byte (an 11*ClksPerBit break here reliably produces one all-1s 0xFF
       byte, confirmed by a standalone uart_rx repro). 0xFF is an unknown
       command, so the device transmits an UNSOLICITED NAK (0x3F) the host
       never asked for -- a real symptom: some USB-UART bridges assert a
       BREAK on port open/close that looks exactly like this to uart_rx
       (guide 6.3.4; fpga/host/attn_host.py's SerialLink drains the RX
       buffer on connect for this reason).

    Both scenarios end with a fresh PING succeeding: the PROTOCOL FSM
    itself never desyncs (P_CMD always correctly interprets the next real
    byte); only the physical layer can produce an extra, spurious response
    that the host must be prepared to see and discard."""
    await start_and_reset(dut)
    link = UartTbLink(dut)

    # Both scenarios are started via start_monitor() BEFORE any stimulus, so
    # the background task is already listening through whatever pipeline
    # delay follows; quiet_cycles here still has to exceed the LONGEST gap
    # before a byte can possibly appear. Scenario 2's worst case is roughly
    # two full failed-attempt windows (the break's own attempt plus the
    # retry it triggers) plus one NAK byte's transmission time; size with
    # generous margin so a byte still in the pipeline is never mistaken for
    # silence (this exact miscalibration was the first version of this fix:
    # too-short a window declared "quiet" before the phantom byte arrived).
    framing_quiet_cycles = 4 * FAILED_ATTEMPT_CYCLES

    # Scenario 1: sub-bit-cell glitch -> false start -> total silence.
    # Released well before the start vote's first sample (Mid-Step), so the
    # vote reads all-1 (idle) and the receiver treats it as a false start.
    mon = link.start_monitor()
    await link.drive_line_low(cycles=max(_MID - _STEP - 2, 1))
    tail = await wait_until_quiet(dut, mon, quiet_cycles=framing_quiet_cycles)
    assert tail == b"", (
        f"sub-bit-cell glitch (false start): expected total silence, got {tail!r}"
    )
    resp = await do_ping(link)
    assert resp == attn_host.RESP_PING, "PING after a silent false-start glitch must succeed"

    # Scenario 2: break spanning a retry -> exactly one spurious NAK.
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
    """TWO reset-recovery scenarios, each followed by a full reload + run +
    readback to prove recovery (RAM contents carry no reset, uarch.md 8.3,
    exactly like tb/attention_top's rst_mid_run convention). Auditor
    finding: the previous single-scenario version of this test claimed
    coverage of "any in-flight UART byte" it did not actually exercise (the
    line was idle at reset time in that scenario); this version either runs
    what it claims or does not claim it.

    1. rst_btn pressed while attention_top is mid-run (cycle-count-wise),
       with the UART line idle -- no byte in flight.
    2. rst_btn pressed literally WHILE a UART byte is mid-transmission on
       the wire (partway through a LOAD_Q data byte's bit cells), proving
       the sync2ff/uart_rx path also recovers cleanly and does not latch
       into a stuck state."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()

    # ---- Scenario 1: mid-run reset, UART line idle -------------------------
    n = 16
    q, k, v = random_qkv(rng, n)
    await load_qkv(link, q, k, v)

    resp = await do_set_nlen(link, n)
    assert resp == attn_host.CMD_SET_NLEN
    resp = await do_run(link)
    assert resp == attn_host.CMD_RUN

    # Let the run get partway through (n=16 is 881 core clocks; 200 is well
    # inside that window). The line is idle here: no byte in flight.
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

    # ---- Scenario 2: reset literally mid-UART-byte -------------------------
    n3 = 8
    q3, k3, v3 = random_qkv(rng, n3)
    frame = attn_host.build_load_row(attn_host.CMD_LOAD_Q, 0, q3[0])
    first_byte = frame[0]
    bits = [0] + [(first_byte >> i) & 1 for i in range(8)] + [1]  # start,d0..d7,stop

    # Drive the first 3 bit cells (start + 2 data bits) of the FIRST frame
    # byte by hand, then assert rst_btn before that byte is anywhere near
    # complete: a real byte is genuinely in flight on the wire at reset.
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
    dut.uart_rx.value = 1  # re-idle the line: the in-flight byte is abandoned

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
    """Abandon a LOAD_Q frame mid-payload (cmd + row + 8 of the 16 data
    bytes, then simply stop -- the FSM is left waiting in P_LDATA for 8 more
    data bytes), run the IMPORTED resync() logic (build_resync_frame +
    is_resynced, the exact functions fpga/host/attn_host.py's
    SerialLink.resync() uses), and prove a full RELOAD + run + readback
    still works afterward. Guide 6.3.4: the resync pings are legal ACT data
    codes/row bytes and get consumed as payload of whatever was mid-flight,
    so rows loaded before a desync are NOT trustworthy -- reloading
    everything (never assuming a partial reload survived) is the point of
    this test, not an afterthought."""
    await start_and_reset(dut)
    link = UartTbLink(dut)
    rng = seeded_rng()
    n = 8
    q, k, v = random_qkv(rng, n)

    partial = attn_host.build_load_row(attn_host.CMD_LOAD_Q, 0, q[0])[:2 + 8]
    await link.send_bytes(partial)

    # start_monitor() inside do_resync begins BEFORE the 18-ping burst is
    # even sent, so by the time send_bytes() returns most/all responses are
    # already captured; a modest post-send quiet window (one byte period,
    # plus margin) is enough here, unlike the framing test's pre-stimulus
    # gap (see that test's comment).
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
async def test_zz_coverage_closure(dut):
    """Must be the LAST test in this file (see module docstring for the
    declaration-order guarantee). Fails loudly if any protocol command
    class was never exercised across the whole regression."""
    missing = REQUIRED_COMMANDS - EXERCISED
    assert not missing, f"protocol command classes never exercised: {sorted(missing)}"
    dut._log.info(f"coverage closure: exercised {sorted(EXERCISED)}")
