# Diagrams: block, dataflow, and the drain-overlaps-compute window

Added 2026-09-19. The Mermaid diagrams render directly on GitHub; the
WaveDrom timing diagram is kept as JSON source in docs/wavedrom/ and
rendered to docs/img/ by `make diagrams` (needs node: `npx wavedrom-cli`),
with an ASCII rendering below so the mechanism is readable without it.
Every signal name matches rtl/attention_top.sv.

## 1. Block diagram (attention_top, docs/uarch.md 8.3)

```mermaid
flowchart LR
    subgraph LOAD["Load port (sel, addr, wdata, we)"]
        direction TB
        Q[("q_word_mem<br/>256 x 32<br/>col-major, 4 rows/word")]
        K[("k_word_mem<br/>256 x 32<br/>col-major, 4 rows/word")]
        V[("v_mem<br/>64 x 128<br/>row-major")]
    end

    FSM["FSM<br/>S_IDLE / S_COMPUTE / S_DRAIN_LAST / S_DIVIDE<br/>counters rg, kb, t, row, div_cnt<br/>prefetch rg_n/kb_n/t_n"]

    TILE["matmul_tile<br/>4x4 output-stationary<br/>16 x mac_unit (ACT x ACT -> SACC)"]
    DBUF["drain_buf<br/>384-bit capture at t=15<br/>+ d=15 outer product"]
    SCONV["score conversion<br/>sat16((sacc+8)>>>4)<br/>rounding site 1"]

    subgraph SM["4 x online_softmax (one per query row / lane)"]
        direction TB
        L0["lane 0: m, l, w, r"]
        L1["lane 1"]
        L2["lane 2"]
        L3["lane 3"]
    end

    PV["shared PV datapath (16 columns)<br/>acc <= rshr(acc*r,15) + w*v<br/>rounding site 4"]
    ACC[("acc_num<br/>4 lanes x 16 x NUM Q10.21")]
    DIV["divider bank (16 x restoring)<br/>out = sat8(floor((2*acc+l)/(2*l)))<br/>rounding site 5"]
    OUT[("out_mem<br/>64 x 128<br/>row-major")]
    RD["rd_addr / rd_data<br/>registered read"]

    Q -- "q_flat (prefetched)" --> TILE
    K -- "k_flat (prefetched)" --> TILE
    FSM -- "en, clr" --> TILE
    TILE -- "acc_flat" --> DBUF
    DBUF -- "one SACC / cycle<br/>lane=t[1:0], key=t[3:2]" --> SCONV
    SCONV -- "s (SCORE)" --> SM
    FSM -- "in_valid, row_start" --> SM
    V -- "v_row_reg (1-cycle RAM latency<br/>= out_valid alignment)" --> PV
    SM -- "w, r, out_valid (one-hot)" --> PV
    PV <--> ACC
    ACC --> DIV
    SM -- "l (denominator)" --> DIV
    DIV -- "out_we, 16 bytes/row" --> OUT
    OUT --> RD
    FSM -- "busy, done, cycle_count" --> RD
```

## 2. Dataflow: what streams, what stays put

```mermaid
flowchart TB
    subgraph GROUP["one query row group rg (4 rows), nblk = n_len/4 key blocks"]
        direction LR
        subgraph B0["block kb = 0<br/>S_COMPUTE, 16 cycles"]
            C0["tile: acc(i,j) += q_i[d] * k_j[d], d = 0..15<br/>Q rows 4rg..4rg+3 broadcast across columns<br/>K rows 0..3 broadcast down rows<br/>partial sums STAY in the 16 accumulators"]
        end
        subgraph B1["block kb = 1<br/>S_COMPUTE, 16 cycles"]
            C1["tile: block 1 accumulates"]
            D0["drain block 0 from drain_buf:<br/>t=0..15 -> (lane t mod 4, key t div 4)<br/>each lane sees its 4 keys in ascending order"]
        end
        subgraph BL["S_DRAIN_LAST, 16 cycles"]
            DL["drain block nblk-1<br/>(no next block to overlap)"]
        end
        subgraph DV["S_DIVIDE, 4 x 35 cycles"]
            DD["row 0..3: load |2*acc+l|, 33 restoring steps, write out_mem"]
        end
    end
    B0 -- "t=15 edge: drain_buf <= acc(d0..14) + q*k(d15)" --> B1
    B1 -- "..." --> BL
    BL --> DV
    DV -- "next group: rg+1, kb=0" --> B0

    style C0 fill:#eef,stroke:#446
    style D0 fill:#efe,stroke:#464
    style DL fill:#efe,stroke:#464
```

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
