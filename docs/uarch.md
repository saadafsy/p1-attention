# uarch.md: Streaming Attention Engine, numeric and microarchitecture spec

Status: Sections 1 to 7 are NORMATIVE as of Phase 0 (they define the bit-exact
contract that model/attn.py, model/attn.cpp, and all later RTL must implement).
Section 8 (dataflow and naming) is a draft that Phase 1 refines; formats in it
are still binding.

This file is the source of truth for naming and numerics. If code and this file
disagree, this file wins and the code is the bug.

## 1. Fixed configuration

| Symbol  | Value | Meaning                                                        |
|---------|-------|----------------------------------------------------------------|
| D       | 16    | head dimension (dot-product length, also output width per row) |
| D_SHIFT | 2     | log2(sqrt(D)); the 1/sqrt(D) scale is an exact right shift     |
| N_MAX   | 256   | architectural max sequence length (accumulators sized for it)  |
| N       | <=64  | project default working sequence length                        |

D is fixed at 16 so that 1/sqrt(D) = 1/4 is an exact power-of-two shift and the
score path needs no scaling multiplier. The same holds for any D = 4^k
(D = 4, 16, 64 give shifts 1, 2, 3). Note: at D = 64 the single all-extreme
input pattern hits the score saturation boundary exactly (see 3.3); at D = 16
score saturation is unreachable. Changing D is a spec change, not a parameter
tweak.

## 2. Number formats (summary)

Notation: Qm.n is signed two's complement with 1 sign bit, m integer bits,
n fractional bits (total 1+m+n). UQm.n is unsigned with m integer and n
fractional bits. "raw" means the stored integer; value = raw * 2^-n.

| Name  | Format | Bits | Raw range              | Used for                            |
|-------|--------|------|------------------------|-------------------------------------|
| ACT   | Q1.6   | 8    | [-128, 127]            | Q, K, V inputs and final output     |
| SACC  | Q11.12 | 24   | [-2^23, 2^23-1]        | Q.K^T dot-product accumulator       |
| SCORE | Q5.10  | 16   | [-32768, 32767]        | scaled score s, running max m       |
| WGT   | UQ1.15 | 16   | [0, 65535], used <=32768 | exp() output w, rescale factor r  |
| DEN   | UQ9.15 | 24   | [0, 2^24-1]            | softmax denominator accumulator l   |
| NUM   | Q10.21 | 32   | [-2^31, 2^31-1]        | weighted-V accumulator acc[k]       |

Intermediate (pre-shift) products, never stored across cycles:

| Expression | Bits | Where                                     |
|------------|------|-------------------------------------------|
| l * r      | 40   | denominator rescale, 24u x 16u            |
| acc * r    | 48   | numerator rescale, 32s x 16u              |
| w * v      | 24   | weight times V element, 16u x 8s, exact   |
| q * k      | 16   | ACT x ACT product inside the MAC, exact   |

## 3. Width derivations

Every width below is derived, not guessed. The models assert these bounds at
runtime so a violation is caught, not silently wrapped.

### 3.1 ACT: Q1.6 in 8 bits

Range [-2, 2), resolution 2^-6 = 0.015625. Chosen for unit-normalized
activations with 2x headroom, on the standard 8-bit datapath width. This is an
input contract, not a derived width; everything else derives from it.

### 3.2 SACC: Q.K^T accumulator, Q11.12 in 24 bits

Product of two Q1.6 values: raw p = a_raw * b_raw, scale 2^(6+6) = 2^12.
Worst case |p_val| = (-2)*(-2) = 4.0 exactly, raw |p| <= 128*128 = 2^14, which
is exact (no rounding: integer multiply).

Sum of D = 16 products: |sacc_raw| <= 16 * 2^14 = 2^18, value <= 64.
Minimum signed width to hold +2^18 is 20 bits. Chosen width 24 (byte aligned,
Q11.12): headroom up to |sum| < 2^23 raw. Note the exact edge: the positive
bound D * 2^14 must stay <= 2^23 - 1, so the headroom claim is D <= 511; at
D = 512 the single all-(-128)^2 pattern sums to exactly +2^23, one past the
signed max. Irrelevant at D = 16 but stated precisely because the mac_unit
testbench pokes at this exact corner.
Accumulation is exact: no rounding, no saturation, overflow impossible by the
bound above (asserted in the models).

### 3.3 SCORE: Q5.10 in 16 bits

s = (q . k) / sqrt(D) = sacc_val / 4 for D = 16.
Bound: |s| <= D * 4 / sqrt(D) = 4 * sqrt(D) = 16.
Integer bits: need +/-16, so 5 integer bits (Q5 spans [-32, 32)); 1+5+10 = 16.

Raw conversion, ONE rounding step (not two):
  s_raw = sat16( (sacc_raw + 8) >> 4 )
Why >>4: sacc scale 2^12 to score scale 2^10 is >>2; divide by sqrt(16) = 4 is
another >>2; combined >>4 with a single add-half (+8 = 2^3) round.
Saturation is defensive only at D = 16: max |s_raw| = (2^18 + 8) >> 4 = 2^14 =
16384 < 32767. (At D = 64 the all-extreme pattern gives exactly 2^20 >> 5 =
32768 which would saturate to 32767; that is why D = 64 is a spec change.)

Why 10 fractional bits: the exponent quantization from score resolution is
2^-11 (half ulp), contributing relative weight error e^(2^-10) - 1 = 0.098%,
one order below the LUT index error (3.5). Score width is therefore not the
accuracy bottleneck, and 16 bits is the natural bus width.

### 3.4 WGT: UQ1.15 in 16 bits

exp(x) for x <= 0 lies in (0, 1]. The value 1.0 must be exact because the
running-max element always has weight exp(0) = 1 (any error there biases every
softmax). raw = 32768 = 0x8000 needs 16 unsigned bits with 15 fractional bits.
Value quantization is 2^-15, two orders below the index error; not the
bottleneck.

### 3.5 exp approximation: direct LUT (normative table = model/exp_lut.hex)

Method: direct-mapped ROM lookup, no interpolation.

| Property   | Value                                                        |
|------------|--------------------------------------------------------------|
| Entries    | 1024 (10-bit index)                                          |
| Entry width| 16 bits unsigned (UQ1.15)                                    |
| ROM size   | 2 KB (one BRAM/SRAM block)                                   |
| Domain     | d in [-16, 0], step 2^-6                                     |
| Generation | lut[j] = floor(2^15 * exp(-j / 2^6) + 0.5), j = 0..1023      |

Index computation from a SCORE-format difference d_raw <= 0:
  d_c   = max(d_raw, -16384)                (clamp to domain; -16.0 in Q5.10)
  idx   = min( (-d_c + 8) >> 4 , 1023 )     (round-half-up to 2^-6 grid)
The difference m_old - m_new (or s - m_new) is computed in 17 bits before the
clamp (two 16-bit values can differ by up to 65535).

The full table lives in model/exp_lut.hex (1024 lines, 4 lowercase hex digits
per line, line j = lut[j]). It is generated only by model/attn.py; attn.cpp and
the RTL ($readmemh) consume the same file, so there is exactly one table in the
project. Duplicating 1024 values here would create a second source of truth;
instead the file is pinned by checksum:

  sha256(model/exp_lut.hex) = 541676bde3a2a703ec0e021960eed77a1806f6182cd4a8d48803e57302e84ba5

Anchor entries (sanity check, from the generated table):

| j    | d = -j/64 | lut[j] | hex    |
|------|-----------|--------|--------|
| 0    |  0.0      | 32768  | 0x8000 |
| 1    | -0.015625 | 32260  | 0x7e04 |
| 64   | -1.0      | 12055  | 0x2f17 |
| 128  | -2.0      |  4435  | 0x1153 |
| 256  | -4.0      |   600  | 0x0258 |
| 512  | -8.0      |    11  | 0x000b |
| 709  | -11.078   |     1  | 0x0001 |
| 710  | -11.094   |     0  | 0x0000 |
| 1023 | -15.984   |     0  | 0x0000 |

Entries 710..1023 are exactly zero: 2^15 * exp(-j/64) < 0.5 for j >= 710.
This gives a natural underflow-to-zero for d <= -11.09 and keeps the index
math a trivial clamp. Dropped probability mass is bounded by
N_MAX * exp(-709/64) = 256 * 1.55e-5 = 0.40% of the denominator (which is
>= 1.0 because the max element contributes exp(0)); at project N = 64 it is
0.10%.

Error of the LUT approximation itself, for d inside the domain:
index rounding moves the exponent by at most half a step, |delta| <= 2^-7,
so the relative weight error is bounded by e^(2^-7) - 1 = 0.784%.
Entry quantization adds at most 2^-16 relative to full scale.

Why a direct LUT and not piecewise linear: PWL with 64 segments would need a
multiplier in the exp path plus a wider ROM entry (base and slope), to push an
error that is already below the output budget (Section 7) further down. The
direct LUT keeps the softmax pipe multiplier-free except for the one rescale
multiplier that online softmax requires anyway. 2 KB of ROM is the cheaper
resource. Revisit only if the Phase 2 benchmark shows the error budget failing.

### 3.6 DEN: denominator accumulator, UQ9.15 in 24 bits

Declared format: UNSIGNED Q9.15, 24 bits, raw range [0, 2^24-1], value
range [0, 512).

l = sum over j of (rescaled) w_j, each w_j <= 1.0. At the project N = 64 the
value reaches at most 64.0, so at least 7 integer bits are required (UQ7
spans [0, 128)). The declared 9 integer bits cover the architectural
N_MAX = 256 (l <= 256 < 512) and byte-align the register to 24 bits.

Overflow proof, BY INDUCTION, including the rounding term (this is the part a
"each term <= 1, so sum <= N" hand-wave skips):

  Claim: after j terms, l_raw <= j * 2^15.
  Base: l_0 = 0.
  Step: l_{j+1} = rshr(l_j * r, 15) + w  with r <= 2^15, w <= 2^15.
    rshr(l_j * r, 15) = floor((l_j * r + 2^14) / 2^15)
    l_j * r + 2^14 <= l_j * 2^15 + 2^14 < (l_j + 1) * 2^15
    so rshr(l_j * r, 15) <= l_j  (the round-half-up bias can NEVER push the
    rescaled value above the unrescaled one, for any r <= 2^15 and any l_j).
    Hence l_{j+1} <= l_j + 2^15 <= (j+1) * 2^15.

  Therefore l_raw <= N * 2^15: at N = 64, l <= 2^21; at N_MAX = 256,
  l <= 2^23 < 2^24 - 1. No overflow, with zero margin consumed by rounding.
  Both models assert 0 <= l < 2^24 on every update, so the bound is machine
  checked on every cross-check run, not just proved on paper.

Lower bound (needed by 3.8): the element that set the final running max
contributed w = lut[0] = 2^15 at its step, and every later step multiplies l
by r = 0x8000 which is bit-exact identity (Section 6, identity 1) before
adding a non-negative w. So at the end of any row, 2^15 <= l_raw <= N * 2^15.

Rescale intermediate l*r is 24u x 16u = 40 bits, never stored.

### 3.7 NUM: weighted-V accumulator, Q10.21 in 32 bits

acc[k] = sum over j of (rescaled) w_j * v_jk. Product scale 2^15 * 2^6 = 2^21.
|w * v| <= 1.0 * 2.0 = 2.0 in value, raw <= 2^15 * 2^7 = 2^22 (24-bit signed,
exact). Sum bound: |acc| <= N * 2 = 512 in value for N = 256, needing 10
integer bits (Q10 spans [-1024, 1024)); 1 + 10 + 21 = 32 bits.
Overflow impossible for N <= 256 (asserted). Rescale intermediate acc*r is
32s x 16u = 48 bits.

### 3.8 Output division: a true divider, NOT a reciprocal LUT

Method: exact integer division (serial restoring divider in RTL), performed
once per output element. Output format Q1.6 int8. Rounding: round-half-up,
the same single policy as everywhere else (Section 4).

Why the scales make the division self-normalizing: num raw = value * 2^21,
den raw = value * 2^15, so
  num_raw / den_raw = out_value * 2^(21-15) = out_value * 2^6
which is exactly the Q1.6 raw output. No pre-shift, no post-shift.

The NORMATIVE quotient definition, identical in both models and binding on
the RTL:
  out_raw = sat8( floor( (2*num_raw + den_raw) / (2*den_raw) ) )
i.e. round-half-up of num/den, expressed in exact integers. In the models:
attn.py divr() uses Python's floor-division operator; attn.cpp divr() goes
through floordiv() because C++ '/' truncates toward zero. floor and
trunc-toward-zero differ exactly when the numerator (2*num + den) is negative
and the division is inexact; the random cross-check cases contain negative
accumulators (random V), so a trunc-vs-floor bug cannot survive make
model-check.

RTL divider algorithm (the direct floor-division realization; latency is
implementation detail, the arithmetic is not):
  A  = 2*num + den        34-bit signed  (|2*num| <= 2^31, den < 2^24)
  B  = 2*den              25-bit unsigned, B >= 2^16 (den >= 2^15, see 3.6)
  qt = |A| / B, rt = |A| mod B     unsigned restoring divide, trunc semantics
  q  = (A >= 0) ? qt : -(qt + (rt != 0))    converts trunc to floor
  out_raw = sat8(q)
The (rt != 0) correction on negative A is exactly the floor adjustment; check:
floor(A/B) for A < 0 equals -ceil(|A|/B) = -(qt + (rt != 0)).

Quotient is tiny: |q| <= 128 (out is a convex combination of int8 v values,
weights summing to exactly 1 in the pre-rounding rationals), so the divider
produces at most 8 magnitude bits. Saturation to [-128, 127] is defensive:
round-half-up of a value <= 127.0 cannot exceed 127.

No division by zero: den_raw >= 2^15 always (lower bound proof in 3.6).

Error bound of this stage: the division is exact up to the single final
rounding, contributing at most 1/2 LSB of Q1.6 (2^-7 in value) to the output.
It adds NO other error term; the Section 7 budget counts it as exactly that.

Why not a reciprocal LUT + multiply: den spans [1, 256] in value (a 23-bit
raw dynamic range), so a direct reciprocal table is either huge or coarse; a
k-bit-index table contributes up to 2^-k RELATIVE error on the whole output,
i.e. another multi-LSB error source on top of Section 7, plus a 32x16
multiplier and a second rounding site that both golden models would have to
replicate. Newton-Raphson refinement needs two more multiplies per output.
The serial divider is one small subtract-shift unit, bit-exactly matches
floor division, and its latency (about 34 cycles once per output element)
hides behind the next row's accumulation in attention_top. Revisit only if
Phase 4 timing shows the divider on the critical path, and then only as a
spec change to this section.

## 4. Rounding policy (single policy, six sites)

One rounding mode everywhere: round-half-up toward +infinity,
  rshr(x, k) = (x + 2^(k-1)) >> k        (arithmetic shift, = floor(x/2^k + 1/2))
  divr(a, b) = floor((2a + b) / (2b))    (b > 0)
Cheap in RTL (one adder, wire shift) and identical in both models. The Python
model relies on Python's floor semantics for >> and //; the C++ model uses an
explicit floordiv helper because C++ integer division truncates toward zero.
This asymmetry is the classic bit-mismatch trap; the cross-check exists to
catch it.

The complete list of rounding sites. Anything not listed is EXACT integer math.

| # | Site                    | Operation                       |
|---|-------------------------|---------------------------------|
| 1 | score scale and shift   | s_raw = (sacc + 8) >> 4         |
| 2 | LUT index quantization  | idx = (-d_c + 8) >> 4           |
| 3 | denominator rescale     | l = rshr(l * r, 15) + w         |
| 4 | numerator rescale       | acc = rshr(acc * r, 15) + w * v |
| 5 | output division         | out = divr-style, Section 3.8   |
| 6 | LUT generation (offline)| floor(2^15 * exp(.) + 0.5)      |

## 5. Saturation and clamp policy (four sites)

| Site                | Behavior                       | Reachable?                          |
|---------------------|--------------------------------|-------------------------------------|
| score to Q5.10      | sat to [-32768, 32767]         | No at D = 16 (proof in 3.3)         |
| diff clamp          | max(d, -16384) before LUT      | Yes, functional (exp underflow)     |
| LUT index clamp     | min(idx, 1023)                 | Yes, only at d = -16.0 exactly      |
| output to Q1.6      | sat to [-128, 127]             | No (proof in 3.8)                   |

Accumulators (SACC, DEN, NUM) have NO saturation logic: they are sized so
overflow is impossible for D = 16, N <= 256 (Sections 3.2, 3.6, 3.7), and both
models assert the bounds on every update.

## 6. Online softmax recurrence (the bit-exact RTL contract)

All quantities are raw integers in the formats of Section 2. Per query row:

  init: m = -32768 (most negative SCORE), l = 0, acc[k] = 0 for all k

  for each key/value index j:
    sacc   = sum over d of q[d] * k_j[d]          exact, 24-bit
    s      = sat16((sacc + 8) >> 4)               SCORE
    m_new  = max(m, s)
    r      = lut[ idx(m - m_new) ]                WGT, rescale factor
    w      = lut[ idx(s - m_new) ]                WGT, this element's weight
    l      = rshr(l * r, 15) + w                  DEN
    acc[k] = rshr(acc[k] * r, 15) + w * v_j[k]    NUM, for every k
    m      = m_new

  out[k] = sat8( floor( (2*acc[k] + l) / (2*l) ) )   Q1.6

### 6.1 The rescale on a running-max update, precisely

When m_new > m, every already-accumulated exp term is implicitly
exp(s - m_old) and must become exp(s - m_new); online softmax does this by one
multiply with r = exp(m_old - m_new), fetched from the SAME LUT as the
weights (no second table, no second approximation method):

  denominator: l   <- rshr(l * r, 15) + w
               l * r is 24u x 16u = 40 bits, never registered;
               rshr adds 2^14 then arithmetic-shifts right 15
               (= floor(x/2^15 + 1/2), round-half-up).
  numerator:   acc <- rshr(acc * r, 15) + w * v
               acc * r is 32s x 16u = 48 bits signed, same rshr;
               the arithmetic shift on a NEGATIVE product is a floor,
               which is exactly what round-half-up requires.

Bit-identity between the models: attn.py rshr() computes
(x + 2^14) >> 15 using Python's floor-semantics shift; attn.cpp rshr()
computes floordiv(x + 2^14, 2^15). These are the same function on all of Z,
including negative acc * r. It is a deliberate pair of DIFFERENT
implementations of one spec, so a floor/trunc confusion in either language
shows up as a cross-check mismatch. The 'monotonic-n64' case exists precisely
for this: its scores strictly increase, forcing a genuine rescale (r < 0x8000)
with sign-mixed accumulators on every one of its 64 steps; the five random
N = 64 cases exercise sparse, irregular max updates.

Rescale error: each real rescale rounds once, at most 1/2 ulp of the target
format (2^-16 of DEN value, 2^-22 of NUM value); at most N-1 rescales can
occur, and steps without a max update contribute ZERO error by identity 1
below. The Section 7 budget carries this as the negligible N * 2^-16 term.

Two identities the RTL may rely on (and the testbench should check):

1. r = 0x8000 (max unchanged) is an EXACT identity: rshr(x * 32768, 15) = x
   for any sign of x, because adding 2^14 to x * 2^15 never reaches the next
   multiple of 2^15. No drift accumulates across steps that do not update the
   running max.
2. First element: m goes from -32768 to s_0, the rescale diff clamps to the
   LUT zero tail so r = 0, and l, acc are 0 anyway; w = lut[0] = 0x8000. So the
   state after j = 0 is exactly (m = s_0, l = 32768, acc[k] = 32768 * v_0[k]).

Streaming note: the recurrence is associative in the FlashAttention sense; the
Phase 2 attention_top processes keys tile by tile carrying (m, l, acc) between
tiles with the same equations, so tiling cannot change the result bit pattern
as long as element order j = 0..N-1 is preserved. Element ORDER matters at the
bit level (rounding is order-dependent); the models and RTL must both process
j in ascending order.

## 7. Error budget vs float attention (bound, then measured)

Per-weight relative error components:

| Source                    | Bound                          |
|---------------------------|--------------------------------|
| LUT index rounding        | e^(2^-7) - 1 = 0.784%          |
| score quantization (2 scores in the diff) | e^(2^-10) - 1 = 0.098% |
| LUT entry quantization    | ~2^-16 = 0.0015%               |
| total eps0                | <= 0.89%                       |

Softmax weights p_i = w_i / sum(w_j) then satisfy |p_hat - p| <= 2*eps0*p to
first order, and since the weights sum to exactly 1, the output error over a
convex combination is bounded by
  |out_err| <= 2*eps0 * (v_max - v_min) <= 2 * 0.0089 * 4 = 0.071  (4.6 LSB)
Additional terms: underflow-to-zero tail <= 0.40% of mass at N_MAX (3.5),
absolute weight quantization across N terms <= N * 2^-16 * spread (about 1 LSB
at N = 64), final division rounding 0.5 LSB, rescale roundings <= N * 2^-16 of
acc scale (negligible).

Acceptance gate used by the model cross-check: max |fixed - float| <= 6 LSB
(0.09375) on every test case. Measured on 2026-07-16 by make model-check over
14 random and corner cases (N up to 256): worst deviation 0.77 LSB (0.0121 in
value), consistent with the bound being loose worst-case.

## 8. Dataflow and naming (draft, refined in Phase 1)

Build order: mac_unit -> matmul_tile -> online_softmax -> attention_top.

| Module         | Function (formats from Section 2)                            |
|----------------|--------------------------------------------------------------|
| mac_unit       | ACT x ACT multiply, SACC accumulate, clr/en control          |
| matmul_tile    | weight-stationary 4x4 grid of mac_unit, K-dim streamed       |
| online_softmax | per-row (m, l) state, LUT, rescale multiplier, emits w and r |
| attention_top  | row streamer, NUM accumulators, final divider, tile control  |

The final divider implements the Section 3.8 algorithm exactly (unsigned
restoring core with the negative-numerator floor correction, about 34 cycles
serial); it is off the per-element critical loop because it runs once per
output element after row accumulation completes.

Naming conventions (binding for all RTL):
- snake_case for signals and modules; module name = file name.
- Registered signals end in _q, their next-state combinational value in _n.
- Active-high synchronous reset named rst, clock named clk, enables named en
  or <x>_en. No latches, every always_comb fully assigned, per CLAUDE.md.
- Format-carrying buses are named with their format when ambiguous, e.g.
  s_q5_10, w_uq1_15.

Golden model files:
- model/attn.py: normative executable spec (pure-integer core, emits
  model/exp_lut.hex, NumPy float reference for the error budget).
- model/attn.cpp: independent reimplementation, required bit-identical;
  consumes the same exp_lut.hex.
- model/crosscheck.py: generates random and corner cases, proves the two
  models bit-identical, reports the measured float error. Run via
  make model-check, which appends the EVIDENCE.md row on success.
