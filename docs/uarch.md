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
the RTL (via generated rtl/exp_lut.svh, see 8.2) consume the same table, so
there is exactly one table in the project. Duplicating 1024 values here would create a second source of truth;
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
| matmul_tile    | output-stationary 4x4 grid of mac_unit, normative spec in 8.1 |
| online_softmax | per-row (m, l) state, LUT, rescale multiplier, emits w and r |
| attention_top  | row streamer, NUM accumulators, final divider, tile control  |

The final divider implements the Section 3.8 algorithm exactly (unsigned
restoring core with the negative-numerator floor correction, about 34 cycles
serial); it is off the per-element critical loop because it runs once per
output element after row accumulation completes.

### 8.1 matmul_tile: 4x4 output-stationary score tile (NORMATIVE, Phase 1)

Function: computes one 4x4 block of the score matrix S = Q.K^T. A grid of
4 x 4 = 16 mac_unit instances; MAC (i, j) accumulates q_i[d] * k_j[d] over
the streamed dimension d = 0..15 (D = 16, Section 1). Each enabled cycle the
tile consumes one element from each of the 4 Q rows and each of the 4 K rows:
the Q element of row i is broadcast across grid row i (all 4 columns), the K
element of row j is broadcast down grid column j. After D enabled cycles
every accumulator holds one exact SACC block element; the whole 4x4 block
completes in the same D cycles as a single dot product.

Dataflow decision: this is an OUTPUT-STATIONARY outer-product-accumulate
array, not the TPU-style weight-stationary systolic array the build sheet's
reference language mentions. The reasons, stated so the deviation is honest:

- On the score path BOTH operands stream. Q and K are per-inference
  activations; there is no long-lived weight matrix that is reused across
  many inputs and therefore worth pinning inside the PEs. Weight-stationary
  wins exactly when one matrix is resident and amortized (the TPU's weights);
  that precondition does not exist here.
- Output-stationary keeps the partial sums in each PE's accumulator, so
  nothing moves between PEs: no systolic skew registers, no partial-sum
  forwarding chain, no drain sequence. The result is read out in place.
- The already-verified mac_unit clr/en contract implements the entire tile
  with ZERO additional datapath: the tile is pure instantiation plus input
  slicing. Any other dataflow would add unverified arithmetic or movement
  logic for no benefit at this size.

The weight-stationary tradeoff (pin one operand in the PEs, stream the
other, pipeline partial sums through the array; amortizes weight loads when
one matrix is reused across a batch) is documented here as an interview
talking point. It is NOT implemented.

Control: the tile is deliberately thin. It re-exports the mac_unit contract
unchanged, with all 16 MACs sharing the same rst, clr, and en:

| rst | clr | en | acc(i,j) next                                    |
|-----|-----|----|--------------------------------------------------|
| 1   | x   | x  | 0                                                |
| 0   | 1   | 1  | q_i[d] * k_j[d]   (new tile, no dead cycle)      |
| 0   | 1   | 0  | 0                                                |
| 0   | 0   | 1  | acc(i,j) + q_i[d] * k_j[d]                       |
| 0   | 0   | 0  | hold                                             |

Ownership split (binding): the d-loop counter and all sequencing (when to
assert en, when to pulse clr, when acc_flat is valid) belong to
attention_top (Phase 2). The tile contains no counters, no FSM, and no state
other than the 16 mac_unit accumulators.

Ports. Flat packed vectors are used for tool portability across verilator,
iverilog, yosys, sby, and cocotb (unpacked-array and array-of-struct ports
are handled inconsistently across that set). Packing convention below.

| Port     | Dir | Width | Meaning                                        |
|----------|-----|-------|------------------------------------------------|
| clk      | in  | 1     | clock                                          |
| rst      | in  | 1     | synchronous, active-high                       |
| en       | in  | 1     | accept one product per MAC this cycle          |
| clr      | in  | 1     | start a new tile this cycle                    |
| q_flat   | in  | 32    | 4 ACT (Q1.6) elements, one per Q row           |
| k_flat   | in  | 32    | 4 ACT (Q1.6) elements, one per K row           |
| acc_flat | out | 384   | 16 SACC (Q11.12, 24-bit) accumulators          |

Packing convention (little-endian slicing, element 0 in the low bits):
- q_flat[8*i +: 8]           = ACT element d of Q row i, i = 0..3
- k_flat[8*j +: 8]           = ACT element d of K row j, j = 0..3
- acc_flat[24*(4*i+j) +: 24] = SACC S block element (row i, col j),
  row-major: element (0,0) is acc_flat[23:0], (0,1) is acc_flat[47:24],
  (3,3) is acc_flat[383:360].

Formats: unchanged from Sections 2 and 3. ACT (Q1.6) in, SACC (Q11.12) out.
Accumulation is exact: no rounding and no saturation anywhere in the tile.
The no-overflow bound is the mac_unit bound D <= 511 (Section 3.2); D = 16
here, so overflow is impossible with large margin.

Naming conventions (binding for all RTL):
- snake_case for signals and modules; module name = file name.
- Registered signals end in _q, their next-state combinational value in _n.
- Active-high synchronous reset named rst, clock named clk, enables named en
  or <x>_en. No latches, every always_comb fully assigned, per CLAUDE.md.
- Format-carrying buses are named with their format when ambiguous, e.g.
  s_q5_10, w_uq1_15.

### 8.2 online_softmax: per-row (m, l) state machine (NORMATIVE, Phase 1)

Function: the per-row online-softmax recurrence of Section 6 for the running
max m (SCORE) and denominator l (DEN), EXCLUDING the NUM path and the final
division (both belong to attention_top). Per consumed score s the module
emits the weight w and rescale factor r (both WGT) that attention_top applies
to its NUM accumulators, plus the current l. Implemented equations, exactly
Section 6 with rounding sites 2 and 3:

  m_new = max(m, s)
  r     = lut[ idx(m - m_new) ]
  w     = lut[ idx(s - m_new) ]
  l     <= rshr(l * r, 15) + w
  m     <= m_new

idx() is the clamp-and-round of 3.5: the differences m - m_new and s - m_new
are computed in 17 bits before the clamp (two 16-bit SCOREs can differ by up
to 65535), clamped to -16384 (-16.0 in Q5.10), then
idx = min((-d_c + 8) >> 4, 1023). rshr is the round-half-up of Section 4.
The l * r intermediate is the 40-bit (24u x 16u) product of Section 2, never
registered. This module contains NO saturation (score saturation is upstream
in the score-scale stage; DEN has no saturation by the 3.6 bound); the two
functional clamps of Section 5 (diff clamp, LUT index clamp) both live here.

Ports (formats from Section 2):

| Port      | Dir | Width | Format       | Meaning                            |
|-----------|-----|-------|--------------|------------------------------------|
| clk       | in  | 1     |              | clock                              |
| rst       | in  | 1     |              | synchronous, active-high           |
| in_valid  | in  | 1     |              | accept score s this cycle          |
| row_start | in  | 1     |              | asserted WITH in_valid on a row's first element: state bases at m = -32768, l = 0 before consuming this s (Section 6 init). Ignored when in_valid = 0. |
| s         | in  | 16    | SCORE Q5.10 signed | score element                |
| w         | out | 16    | WGT UQ1.15   | lut[idx(s - m_new)], registered    |
| r         | out | 16    | WGT UQ1.15   | lut[idx(m - m_new)], registered    |
| out_valid | out | 1     |              | w and r are valid; high exactly one cycle after each accepted s |
| l         | out | 24    | DEN UQ9.15   | current denominator register, continuously visible |
| m         | out | 16    | SCORE Q5.10 signed | current running max, continuously visible (debug and formal) |

Timing: single-cycle recurrence, throughput one element per cycle, no
backpressure (the module always accepts when in_valid is high). The (m, l)
state updates on the clock edge that consumes s; w, r, out_valid are
registered on the SAME edge. Consequence: during an out_valid cycle the
visible l already includes the element that (w, r) describe, and
attention_top applies acc <= rshr(acc * r, 15) + w * v in that same
out_valid cycle, so the same r that rescaled l rescales the NUM accumulators
one cycle later, keeping both states element-consistent. Rows may be issued
back to back: row_start with in_valid may follow the previous row's last
element with no dead cycle (the previous element's out_valid overlaps the
new row's first accepted cycle; attention_top's own sequencing tells them
apart).

Cycle diagram, one 3-element row (registered state shown as visible DURING
each cycle; mj = running max after elements 0..j, lj = l after elements 0..j):

  cycle       |  0   |  1     |  2     |  3     |  4
  in_valid    |  1   |  1     |  1     |  0     |  0
  row_start   |  1   |  0     |  0     |  0     |  0
  s           |  s0  |  s1    |  s2    |  x     |  x
  m (visible) |  old |  s0    |  m1    |  m2    |  m2
  l (visible) |  old |  l0    |  l1    |  l2    |  l2
  out_valid   |  0   |  1     |  1     |  1     |  0
  w (visible) |  x   |  w(s0) |  w(s1) |  w(s2) |  w(s2)
  r (visible) |  x   |  r(s0) |  r(s1) |  r(s2) |  r(s2)

At cycle 0 the module ignores the stale (m, l) via row_start and bases the
step at (m = -32768, l = 0); by Section 6 identity 2 the cycle-1 visible
state is exactly (m = s0, l = 32768) with w = 0x8000 and r = 0.

exp LUT realization: a COMBINATIONAL ROM inside the module, defined by the
generated include rtl/exp_lut.svh (a synthesizable constant case function,
exp_lut_rom, 1024 x 16 bit). It is emitted ONLY by
'python3 model/attn.py --emit-lut-svh rtl/exp_lut.svh', is never hand-edited,
and must match model/exp_lut.hex entry for entry (the testbench re-checks all
1024 entries against the hex). This keeps 3.5's single generation source:
model/exp_lut.hex remains the normative interchange artifact (sha256-pinned
in 3.5) consumed by attn.cpp; the .svh is the same table rendered
synthesizable, avoiding a $readmemh initial block (banned by the RTL coding
standard) and memory-file path resolution differences across the
verilator/yosys/sby working directories. The w and r lookups are two
combinational reads of the same constant table (two ROM muxes after
synthesis; 2 KB scale, no memory macro implied). The RTL `include path is
"rtl/exp_lut.svh", resolved relative to the repo root for make lint and
synth-check; flows that run tools from another working directory must map it
(cocotb: an include dir pointing at the repo root; sby: a [files] line with
destination path rtl/exp_lut.svh).

Pipelining hook (Phase 4): the single-cycle combinational path
diff -> clamp -> index -> ROM -> (l * r multiply) -> rshr -> add is the
expected critical path of the whole design. The planned Phase 4 iteration is
a registered-ROM variant (register w and r out of the lookup, moving the
multiply/accumulate to the next stage); the recurrence arithmetic is
unchanged, only latency and the out_valid alignment shift. Any such change
updates this section first.

Golden model files:
- model/attn.py: normative executable spec (pure-integer core, emits
  model/exp_lut.hex and the generated rtl/exp_lut.svh rendering of it,
  NumPy float reference for the error budget).
- model/attn.cpp: independent reimplementation, required bit-identical;
  consumes the same exp_lut.hex.
- model/crosscheck.py: generates random and corner cases, proves the two
  models bit-identical, reports the measured float error. Run via
  make model-check, which appends the EVIDENCE.md row on success.

### 8.3 attention_top: 4-row-blocked integration (NORMATIVE, Phase 2)

Function: stitches matmul_tile (8.1) and online_softmax (8.2), unchanged, into
the full streaming attention recurrence of Section 6, for N = n_len rows
self-attention (Q, K, V all n_len x D=16), n_len a multiple of 4 in [4, 64].
This module owns the NUM accumulators (3.7), the score conversion (3.3,
rounding site 1) and the output divider (3.8, rounding site 5); mac_unit,
matmul_tile and online_softmax are instantiated exactly as verified, no
changes.

Dataflow decision: query rows are processed in groups of 4 (matching the
tile's 4x4 shape). Per group, key/value blocks of 4 are streamed through
matmul_tile one D=16-cycle block at a time; while block b+1 computes, block
b's already-finished 4x4 SACC block is drained into 4 online_softmax
instances (one per query row / "lane" in the group), one score per lane
every 4 cycles, round-robin over the block's 16-cycle period. This is a
software-pipelined double buffer: matmul_tile's own accumulator IS one
buffer; a captured 384-bit register (drain_buf) is the other. The capture
happens on the same clock edge that starts the next block's clr, so there
is no dead cycle (mirrors matmul_tile's own back-to-back clr contract,
tb/matmul_tile/test_matmul_tile.py golden_block_streaming).

Capture value, precisely (the one subtlety that is easy to get wrong by one
cycle): at the edge ending the block's t=15 cycle, matmul_tile's acc_flat is
ANOTHER module's registered output; a same-edge register-to-register read
sees the PRE-edge value by NBA semantics, which at that instant still holds
only the sum through d=0..14 (d=15's product takes effect only via that same
edge's own NBA update, i.e. one edge later than a naive capture would
assume). Rather than shift the whole round-robin read schedule by a cycle
to compensate, attention_top computes the missing d=15 outer product
combinationally, from that same cycle's own q_flat/k_flat (which already
carry the d=15 operands), and adds it to acc_flat before registering
drain_buf: drain_buf <= acc_flat + (q_flat . k_flat outer product at d=15).
This keeps the capture aligned exactly at t=15 with no extra cycle and no
window-straddling read timing elsewhere.

Round-robin addressing: over cycle t = 0..15 of a block period,
lane = t[1:0] (t mod 4, the query row within the group), key_local = t[3:2]
(t / 4, the key row within the drained block, ascending). This preserves
per-lane ascending key order (Section 6's "element order matters" streaming
note): lane L sees key_local 0,1,2,3 in that order, at cycles L, L+4, L+8,
L+12.

Score conversion (rounding site 1, 3.3) happens at drain time, combinationally,
once per cycle, from whichever (lane, key_local) element of drain_buf is
addressed that cycle: s = sat16((sacc + 8) >>> 4). Only one element is
converted per cycle (matching one online_softmax accept per cycle), so no
separate 16-wide SCORE buffer is needed.

Since query and key/value share one n_len, the number of query row groups
equals the number of key/value blocks: nblk = n_len / 4. The FlashAttention
carry (Section 6's (m, l) running max/denominator across key blocks) is
exactly online_softmax's own (m, l) state persisting across the nblk drains
of one row group; attention_top does not re-derive it, it only sequences
which SACC block feeds which lane when.

PV (numerator) path: on lane L's out_valid (one cycle after in_valid, per
online_softmax's own timing contract, 8.2), attention_top updates lane L's
16-wide NUM bank in that one cycle, k-parallel:
  acc_base[k] = row_start_d[L] ? 0 : acc[L][k]     (mirrors online_softmax's
                                                     own l_base pattern)
  acc[L][k]  <= rshr(acc_base[k] * r, 15) + w * v_row[k]     (3.7, 6.1)
r, w come from lane L's registered outputs; v_row is V's row for the element
that produced this (w, r), i.e. the SAME v row that was fed to the lane one
cycle earlier. Because round-robin guarantees at most one lane fires
out_valid on any given cycle in steady state, and even at the two lane
handoffs the writes target disjoint (lane, k) storage, ONE shared 16-wide PV
datapath (16 parallel rescale-multiply-add lanes, replicated by k) suffices;
it is instantiated once and driven by whichever lane's out_valid is
currently high. Two 1-cycle pipeline registers per lane (row_start_d[L],
vrow_pipe[L]) carry row_start and the V row address from the in_valid cycle
to the out_valid cycle, exactly mirroring online_softmax's internal
row_start-to-l_base alignment (8.2) so acc[L] resets to 0 on the row's first
element instead of accumulating stale data from the previous row group.

acc*r intermediate: 48-bit signed (32s x 16u, 3.7/6.1); rshr rounds with the
same round-half-up bias as online_softmax's l path, arithmetic-shifted so a
negative acc*r floors correctly (6.1). w*v intermediate: 24-bit signed exact
(16u x 8s, Section 2). Truncating the wide rescaled intermediate down to the
32-bit NUM register (after rounding) is safe by the same style of argument as
online_softmax's l_resc truncation (8.2): the 3.7 induction bound guarantees
the true value always fits.

Divider bank (3.8, rounding site 5, exactly the normative algorithm, no
shortcuts): after a row group's last drain (S_DRAIN_LAST below) the row's
(acc[L][*], l[L]) are stable (no more in_valid pulses touch them), so the
divisions for that group's 4 rows run sequentially, one row at a time, a
16-wide bank of serial restoring dividers (one instance per k, replicated,
identical control):
  A = 2*num + den      34-bit signed   (2*num via <<< 1 into a 34-bit signed
                                         register, den zero-extended)
  B = 2*den             25-bit unsigned (den << 1; shared across the 16 k
                                         dividers of one row, since l is
                                         per-row not per-k)
  |A| fits 33 bits given the 3.7/3.6 bounds; the divider loads absA (33 bits,
  sign recorded separately), then performs 33 shift-subtract restoring
  iterations (bit 32 down to bit 0 of absA), each iteration: shift the next
  absA bit into a 25-bit remainder register (giving a 26-bit trial value),
  subtract B if the trial is >= B (restoring semantics), shift a 1 or 0 into
  a 33-bit quotient shift register. After 33 iterations, qt (33-bit unsigned)
  and rt (25-bit unsigned remainder, always < B) are exact. Sign correction
  and floor conversion, then sat8, exactly per 3.8:
    q = (A >= 0) ? qt : -(qt + (rt != 0))
    out_raw = sat8(q)
  Per-row divider timing: 1 load cycle + 33 iterate cycles + 1 write cycle
  (writes all 16 out_raw values to the output buffer row) = 35 cycles/row,
  4 rows sequential per group = 140 cycles/group. This is deliberately NOT
  overlapped with the next group's compute (correctness first, per the
  build brief); the next group's S_COMPUTE only starts after all 4 rows of
  the current group finish dividing. Overlapping the divide phase with the
  next group's block-0 compute (which has no drain dependency) is a valid
  future optimization, not implemented here.

n_len contract: the golden model (model/attn.py attn_fixed) accepts any
1 <= N <= 256. This hardware module requires n_len a multiple of 4 in
[4, 64] (4-row query groups and 4-row key/value blocks with no partial-tile
handling); n_len is latched into nblk_reg = n_len[6:2] on the start edge and
is not re-sampled until the next start.

Ports:

| Port        | Dir | Width | Meaning                                             |
|-------------|-----|-------|------------------------------------------------------|
| clk         | in  | 1     | clock                                                |
| rst         | in  | 1     | synchronous, active-high                             |
| sel         | in  | 2     | which RAM the load port writes: 0=Q, 1=K, 2=V, 3=unused (no write) |
| addr        | in  | 10    | {row[5:0], col[3:0]}, load-port write address        |
| wdata       | in  | 8     | ACT Q1.6, load-port write data                       |
| we          | in  | 1     | load-port write enable                               |
| n_len       | in  | 7     | sequence length; multiple of 4, 4 <= n_len <= 64      |
| start       | in  | 1     | pulse; begins a run when busy = 0                    |
| busy        | out | 1     | 1 while a run is in progress                          |
| done        | out | 1     | one-cycle pulse the cycle the run returns to idle     |
| rd_addr     | in  | 10    | output buffer read address, {row[5:0], col[3:0]}     |
| rd_data     | out | 8     | ACT Q1.6, registered one cycle after rd_addr           |
| cycle_count | out | 32    | cycles elapsed since the accepted start pulse          |

Internal storage (Block-RAM-inferable, revised from the original register-array
version): four synchronous memories, each with exactly ONE write port and ONE
synchronous read port (`always_ff`, indexed by a runtime address, no per-
element unrolled write logic) -- the canonical single-port RAM-inference
idiom yosys keeps as a `$mem_v2` cell (and that Vivado/other BRAM-aware
flows map onto a real Block RAM), instead of the original `logic [7:0]
q_mem[64][16]` etc. register arrays whose 1024-way per-element `genvar`
write loop synthesized to roughly 32k individual flip-flops plus a large
combinational address-decode/mux structure for the tile's multi-row reads
(measured: yosys `hierarchy;proc;opt;memory -nomap;stat` on the register-
array version shows ZERO `$mem_v2` cells owned by attention_top -- the
arrays never form a recognizable memory object at all, confirmed by the
per-bit register names yosys assigns, e.g. `q_mem[1023]`; full `synth`
takes 5m23s wall / 4.77 GB peak on that version, driven by ~72k `$eq`
cells from the multi-address combinational reads, versus 1m15s wall / 1.25
GB peak on the revised version below; `sby` BMC depth 10 drops from the
~1 minute the original attention_top.sby documented to 2.8s).

- q_mem, k_mem: COLUMN-MAJOR, word-packed 4 ACT bytes/word (`q_word_mem`,
  `k_word_mem`, each `logic [31:0] mem [256]`, word address = {group[3:0],
  col[3:0]} where group is rg for Q, kb for K). One word IS q_flat/k_flat
  (8.1's own little-endian lane packing: lane i in bits [8*i+:8]), so a
  SINGLE synchronous read per cycle delivers the tile feed directly with
  no combinational multi-row decode. This is the geometry change flagged
  in the tradeoff: the byte-granular load-port write (row, col) is split
  into word address {row[5:2], col[3:0]} and byte lane row[1:0] (the row's
  position within its group of 4), a one-of-4-byte-lane write into an
  otherwise-unread word, synthesizable as the standard partial-word BRAM
  write. The read address is PREFETCHED one cycle early: rg_n/kb_n/t_n
  (the FSM's own next-state value for rg/kb/t, computed combinationally,
  the same case structure as the sequential update) drive the read port
  this cycle, so the RAM's registered output lands, next cycle, exactly
  the value a combinational read of the CURRENT (rg, kb, t) used to give.
  Zero added latency; the cycle_count formula (below) is unchanged and was
  re-verified bit-exactly by the existing testbench after this change.
- v_mem: ROW-MAJOR, 16 ACT bytes/word (`logic [127:0] v_mem [64]`, one V
  row = one word), matching the drain path's whole-row access pattern.
  Byte-granular writes use the natural row/col split (word = row, byte
  lane = col). The read address is drain_v_row, the SAME combinational
  signal that drives online_softmax's in_valid this cycle; the RAM's own
  1-cycle synchronous-read latency lands the row on the out_valid cycle
  one cycle later (online_softmax's fixed in_valid -> out_valid latency,
  8.2), which is exactly the alignment a separate per-lane vrow_pipe
  address register used to provide by hand in the register-array version.
  Because round-robin draining guarantees at most one lane's out_valid is
  high on any cycle (lane = t[1:0] is single-valued each cycle, and
  out_valid is one cycle behind in_valid), one shared read port correctly
  serves whichever lane is active, with no address pipeline register at
  all.
- out_mem: ROW-MAJOR, 16 ACT bytes/word (`logic [127:0] out_mem [64]`),
  written WHOLE (all 16 bytes, one word) on out_we by the divider bank
  (no byte lanes needed on this port), and read back byte-granular through
  the registered rd_addr/rd_data port (`rd_data <= out_mem[row][8*col+:8]`,
  a single always_ff, valid one cycle after rd_addr, unchanged in
  observable timing from the original).

Confirmed geometry (yosys `memory -nomap`, attention_top-level `$mem_v2`
cells, all WR_PORTS=1 RD_PORTS=1): q_word_mem SIZE=256 WIDTH=32,
k_word_mem SIZE=256 WIDTH=32, v_mem SIZE=64 WIDTH=128, out_mem SIZE=64
WIDTH=128 (8192 bits each, matching the packing above exactly).

None of the four RAM arrays carry a reset term: an `if (rst)` branch that
touches RAM contents is exactly what blocks single-port BRAM inference (it
forces per-bit set/reset logic into every cell). Correctness without a
contents reset relies entirely on the load-before-use protocol already
required by this module's contract: the FSM only ever indexes rows
0..n_len-1 (rg, kb range over nblk = n_len/4 groups/blocks, never beyond),
and every testbench (tb/attention_top/test_attention_top.py) writes the
full n_len x D matrices before pulsing start, so no read ever reaches an
un-written location. Only ordinary CONTROL/pipeline registers derived from
RAM reads (q_flat, k_flat, v_row_reg, rd_data) carry the usual synchronous
reset, per CLAUDE.md's "reset every sequential element" rule; this does not
reintroduce a reset on the RAM arrays themselves.

FSM states:

| State        | What happens                                                            |
|--------------|--------------------------------------------------------------------------|
| S_IDLE        | busy = 0; on start, latch nblk_reg = n_len[6:2], zero rg/kb/t, go to S_COMPUTE |
| S_COMPUTE     | 16 cycles (t = 0..15, d = t): matmul_tile streams block kb of the current row group (clr at t=0, en=1 throughout); if kb != 0, concurrently drains block kb-1 (round-robin as above). At t=15, drain_buf <= acc_flat (capture); if kb == nblk_reg-1 go to S_DRAIN_LAST else kb <= kb+1 and repeat |
| S_DRAIN_LAST  | 16 more cycles, same round-robin drain, no tile compute: drains the final block (nblk_reg-1) that S_COMPUTE could not overlap. At t=15, go to S_DIVIDE, row <= 0, div_cnt <= 0 |
| S_DIVIDE      | 35 cycles/row x 4 rows (div_cnt: 0=load, 1..33=iterate, 34=write-and-advance). After row 3's write: if rg == nblk_reg-1, go to S_IDLE with done = 1; else rg <= rg+1, kb <= 0, t <= 0, go to S_COMPUTE for the next row group |

busy = (state != S_IDLE). done is a registered pulse, true only on the cycle
the FSM lands back in S_IDLE from a run (so busy and done are never both 1,
and done implies state == S_IDLE by construction). cycle_count resets to 1
on the accepted start edge and increments every cycle while busy, holding at
its final value once done (a benchmark readback of total run length).

Cycle formula: for a run with nblk = n_len/4 row groups (= key/value blocks):
  cycles/group = (nblk + 1) * 16 (compute+drain) + 4 * 35 (divide) = 16*nblk + 156
  total        = nblk * (16*nblk + 156) + 1 (start edge)
At n_len = 64 (nblk = 16): total = 16*(256 + 156) + 1 = 16*412 + 1 = 6593
cycles. At n_len = 4 (nblk = 1): total = 1*(16+156)+1 = 173 cycles. These are
the closed-form counts before any pipelining of the divide phase across
group boundaries (documented above as future work); the smoke-sim
cycle_count value is the authoritative check for the exact constant term.

FORMAL block (control-only, per CLAUDE.md's formal-is-a-subset rule):
reset state (S_IDLE, busy=0, done=0, cycle_count=0), busy/done mutual
exclusion, done implies idle, cycle_count monotone non-decreasing while
busy. None of these properties reference q_mem/k_mem/v_mem/out_mem, the
NUM accumulators, the score/rescale arithmetic, or the divider bank: the
control FSM's transition conditions depend only on counters (t, kb, rg,
row, div_cnt) and start, never on datapath values, so this stays solver-
cheap by construction even though the full netlist still elaborates the
datapath as part of the design.
