# Diagrams: block, dataflow, and the drain-overlaps-compute window

The block diagram is a hand-drawn SVG (docs/img/attention_top_block.svg).
The timing diagram is kept as WaveDrom JSON in docs/wavedrom/ and rendered
to docs/img/ by `make diagrams` (needs node: `npx wavedrom-cli`), with a
text rendering below so the mechanism is readable without it. Every signal
name matches rtl/attention_top.sv.

## 1. Block diagram (attention_top, docs/uarch.md 8.3)

![attention_top block diagram](img/attention_top_block.svg)

Names in the RTL, for reading alongside the picture:

| Block in the picture | RTL | Notes |
|---|---|---|
| Q RAM, K RAM | q_word_mem, k_word_mem | 256 x 32, column-major, 4 rows per word, prefetched into q_flat / k_flat |
| V RAM | v_mem | 64 x 128, row-major; v_row_reg gives the 1-cycle read latency that lines up with out_valid |
| control FSM | S_IDLE, S_COMPUTE, S_DRAIN_LAST, S_DIVIDE | counters rg, kb, t, row, div_cnt; prefetch rg_n / kb_n / t_n |
| matmul_tile | u_tile | 4x4 output-stationary, 16 mac_unit, driven by en / clr |
| drain_buf | drain_buf | 384-bit capture at t = 15 plus the d = 15 product; one score per cycle, lane = t[1:0], key = t[3:2] |
| score conversion | sat16((sacc+8)>>>4) | rounding site 1 |
| online_softmax x 4 | one per query row | m, l, w, r per lane; in_valid / row_start from the FSM |
| PV datapath | 16 shared columns | acc <= rshr(acc*r,15) + w*v, rounding site 4; acc_num is 4 lanes x 16 x Q10.21 |
| divider bank | 16 restoring dividers | out = sat8(floor((2*acc+l)/(2*l))), rounding site 5; writes 16 bytes per row |
| out RAM | out_mem | 64 x 128, registered read on rd_addr / rd_data |

## 2. Dataflow: what streams, what stays put

One query row group rg (4 rows), nblk = n_len/4 key blocks:

```
state         S_COMPUTE      S_COMPUTE           ...  S_DRAIN_LAST      S_DIVIDE
block         kb = 0         kb = 1                   (no new block)    rows 0..3
cycles        16             16                       16                4 x 35
tile          accumulates 0  accumulates 1             idle              idle
drain         -              drains block 0            drains nblk-1     -
divider       -              -                         -                 |2*acc+l|, 33 steps,
                                                                         write out_mem
then: rg + 1, kb = 0, back to S_COMPUTE
```

At the t = 15 edge of each block: drain_buf <= acc(d0..14) + q*k(d15).
In block kb the tile computes acc(i,j) += q_i[d] * k_j[d] for d = 0..15,
with Q rows 4rg..4rg+3 broadcast across columns and K rows broadcast
down rows; the partial sums stay in the 16 accumulators. The drain of
block kb-1 feeds lane t mod 4, key t div 4, so each lane sees its 4 keys
in ascending order.

Output-stationary in one sentence: the 16 partial sums never move
between PEs; Q and K elements stream past them for 16 cycles and the
finished block is read out in place (into drain_buf) on the last edge.

## 3. Timing: drain overlaps compute, and the d=15 fold-in

Window: cycles t=13, 14, 15 of block kb (kb >= 1, so block kb-1 is being
drained) and t=0, 1 of block kb+1. Values are as VISIBLE DURING the cycle
(after the edge that started it). Source: docs/wavedrom/drain_overlap.json.

```
cycle        | t=13 blk kb | t=14 blk kb | t=15 blk kb | t=0 blk kb+1 | t=1 blk kb+1
state        | S_COMPUTE   | S_COMPUTE   | S_COMPUTE   | S_COMPUTE    | S_COMPUTE
tile_en      | 1           | 1           | 1           | 1            | 1
tile_clr     | 0           | 0           | 0           | 1            | 0
q_flat/k_flat| d13 of kb   | d14 of kb   | d15 of kb   | d0 of kb+1   | d1 of kb+1
acc_flat     | kb: d0..12  | kb: d0..13  | kb: d0..14  | kb: d0..15   | kb+1: d0
drain_buf    | blk kb-1    | blk kb-1    | blk kb-1    | blk kb (new) | blk kb
             |             |             | ^ edge: drain_buf <= acc_flat(d0..14) + q_flat*k_flat(d15)
lane in_valid| lane 1      | lane 2      | lane 3      | lane 0       | lane 1
key_local    | 3           | 3           | 3           | 0            | 0
s (score)    | S[1][3] kb-1| S[2][3] kb-1| S[3][3] kb-1| S[0][0] kb   | S[1][0] kb
out_valid    | lane 0      | lane 1      | lane 2      | lane 3       | lane 0
             | (S[0][3])   | (S[1][3])   | (S[2][3])   | (S[3][3])    | (S[0][0] kb)
v_row_reg    | V row 4(kb-1)+3 for each out_valid above (read presented on the in_valid cycle)
```

The one subtlety: at the edge ending t=15, acc_flat is another module's
registered output and still holds d0..14 (its own d15 update lands on
that same edge). Rather than delay the whole drain schedule by a cycle,
drain_buf_next adds the d=15 product from the same cycle's q_flat/k_flat,
so the capture is the complete 16-term block and block kb starts draining
at t=0 with no dead cycle. During t=0 acc_flat briefly shows the complete
old block (d0..15) before clr replaces it with the new d0 on the next edge;
nothing reads it then, drain_buf is the source.

Row-start: the first drained element of a group (kb-1 = 0, key_local = 0,
t = lane) carries row_start into the lane's online_softmax and, one cycle
later through row_start_d, rebases that lane's acc_num bank to 0.
