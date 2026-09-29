// tile_coverage: functional coverage sampled from the monitor's observed
// transactions. Bins are the corners docs/uarch.md 8.1 / 3.2 make
// meaningful at the TILE boundary. Two bins the target-scores brief asked
// for are deliberately absent: "saturation hit" and "round-half-up tie".
// matmul_tile has no saturation and no rounding site (exact integer
// accumulation, uarch.md 8.1); those corners live at attention_top's
// score conversion and are covered by tb/attention_top's functional model.
// Claiming them here would be coverage of something the DUT does not do.
class tile_coverage extends uvm_subscriber #(tile_seq_item);
  `uvm_component_utils(tile_coverage)

  tile_seq_item tr;
  int lane;               // 0..3, sampled once per lane per transaction
  bit signed [7:0] qv, kv;
  bit signed [23:0] accv;
  int unsigned dot_len;   // enabled beats since the last clr&&en
  bit prev_en;

  covergroup cg_operands;
    option.per_instance = 1;
    // sign of each operand and their combination, per lane
    cp_qsign: coverpoint qv {
      bins neg = {[-128:-1]};
      bins zero = {0};
      bins pos = {[1:127]};
    }
    cp_ksign: coverpoint kv {
      bins neg = {[-128:-1]};
      bins zero = {0};
      bins pos = {[1:127]};
    }
    cx_signs: cross cp_qsign, cp_ksign;
    // magnitude buckets of the Q1.6 code (0, tiny, half scale, full scale)
    cp_qmag: coverpoint qv {
      bins min_m128 = {-128};
      bins low_mag = {[-15:-1], [1:15]};
      bins mid = {[-127:-16], [16:126]};
      bins max_127 = {127};
      bins zero = {0};
    }
    cp_kmag: coverpoint kv {
      bins min_m128 = {-128};
      bins low_mag = {[-15:-1], [1:15]};
      bins mid = {[-127:-16], [16:126]};
      bins max_127 = {127};
      bins zero = {0};
    }
    cp_lane: coverpoint lane { bins l[] = {[0:3]}; }
    // operand magnitude against lane: every lane sees every magnitude class
    cx_qmag_lane: cross cp_qmag, cp_lane;
    cx_kmag_lane: cross cp_kmag, cp_lane;
  endgroup

  covergroup cg_control;
    option.per_instance = 1;
    cp_ctrl: coverpoint {tr.rst, tr.clr, tr.en} {
      bins reset = {3'b100, 3'b101, 3'b110, 3'b111};
      bins clr_en = {3'b011};   // load, no dead cycle
      bins clr_only = {3'b010}; // clear
      bins accum = {3'b001};
      bins hold = {3'b000};
    }
    // full D=16 dot products completed, and the in-spec bound edge
    cp_dot_len: coverpoint dot_len {
      bins one = {1};
      bins partial = {[2:15]};
      bins full_16 = {16};
      bins over_16 = {[17:$]};   // longer than D: exercises headroom, still in spec (<= 511)
    }
    cp_hold_after_en: coverpoint {prev_en, tr.en} { bins en_to_hold = {2'b10}; bins hold_to_en = {2'b01}; }
  endgroup

  covergroup cg_acc;
    option.per_instance = 1;
    // SACC magnitude classes up to the D=16 extremum 16 * 2^14 = 2^18
    cp_acc: coverpoint accv {
      bins zero = {0};
      bins low_mag = {[-4095:-1], [1:4095]};
      bins mid = {[-131071:-4096], [4096:131071]};
      bins near_extremum = {[-262144:-131072], [131072:262144]};
      bins beyond_d16 = {[-8388608:-262145], [262145:8388607]}; // only reachable past D=16
    }
    cp_acc_sign: coverpoint accv { bins neg = {[-8388608:-1]}; bins zero = {0}; bins pos = {[1:8388607]}; }
    cp_lane_acc: coverpoint lane { bins l[] = {[0:3]}; }
    cx_acc_lane: cross cp_acc, cp_lane_acc;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_operands = new();
    cg_control = new();
    cg_acc = new();
    dot_len = 0;
    prev_en = 0;
  endfunction

  function void write(tile_seq_item t);
    tr = t;
    if (t.rst) dot_len = 0;
    else if (t.clr && t.en) dot_len = 1;
    else if (t.en) dot_len++;
    else if (t.clr) dot_len = 0;
    cg_control.sample();
    prev_en = t.en;
    for (int i = 0; i < 4; i++) begin
      lane = i;
      qv = t.q[i];
      kv = t.k[i];
      if (t.en && !t.rst) cg_operands.sample();
      accv = t.obs_acc[4*i+i];  // diagonal element (i,i) as the lane's representative
      cg_acc.sample();
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("functional coverage: operands %.1f%%, control %.1f%%, acc %.1f%%",
              cg_operands.get_inst_coverage(), cg_control.get_inst_coverage(),
              cg_acc.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
