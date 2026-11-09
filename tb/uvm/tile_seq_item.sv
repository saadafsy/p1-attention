// tile_seq_item: one clock edge of matmul_tile stimulus (rst > clr > en,
// 4 Q and 4 K codes), plus the expected acc_flat for replayed items.
class tile_seq_item extends uvm_sequence_item;
  rand bit               rst;
  rand bit               en;
  rand bit               clr;
  rand bit signed [ 7:0] q[4];   // ACT Q1.6 codes, one per Q row (lane)
  rand bit signed [ 7:0] k[4];   // ACT Q1.6 codes, one per K row
  bit                    has_expected;  // 0: no golden value (random test)
  bit signed [23:0]      exp_acc[16];
  bit signed [23:0]      obs_acc[16];   // acc_flat after this edge (monitor)
  int unsigned           cycle;         // edge this stimulus is applied at

  // rst rare, en mostly on, clr rare.
  constraint c_ctrl {
    rst dist {1 := 2, 0 := 98};
    en  dist {1 := 85, 0 := 15};
    clr dist {1 := 8, 0 := 92};
  }
  // Full Q1.6 range, edge values weighted up so the (-128)*(-128) = 2^14
  // corner is hit often.
  constraint c_q {
    foreach (q[i]) q[i] dist {
      -128 := 4, -64 := 3, -1 := 3, 0 := 3, 1 := 3, 63 := 3, 127 := 4,
      [-127:-65] := 2, [-63:-2] := 2, [2:62] := 2, [64:126] := 2
    };
  }
  constraint c_k {
    foreach (k[i]) k[i] dist {
      -128 := 4, -64 := 3, -1 := 3, 0 := 3, 1 := 3, 63 := 3, 127 := 4,
      [-127:-65] := 2, [-63:-2] := 2, [2:62] := 2, [64:126] := 2
    };
  }

  `uvm_object_utils_begin(tile_seq_item)
    `uvm_field_int(rst, UVM_ALL_ON)
    `uvm_field_int(en, UVM_ALL_ON)
    `uvm_field_int(clr, UVM_ALL_ON)
    `uvm_field_sarray_int(q, UVM_ALL_ON)
    `uvm_field_sarray_int(k, UVM_ALL_ON)
    `uvm_field_int(has_expected, UVM_ALL_ON)
    `uvm_field_sarray_int(exp_acc, UVM_ALL_ON)
    `uvm_field_sarray_int(obs_acc, UVM_ALL_ON)
    `uvm_field_int(cycle, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "tile_seq_item");
    super.new(name);
  endfunction

  // Lane i in bits [8*i +: 8].
  function logic [31:0] q_flat();
    logic [31:0] f = '0;
    foreach (q[i]) f[8*i+:8] = q[i];
    return f;
  endfunction

  function logic [31:0] k_flat();
    logic [31:0] f = '0;
    foreach (k[i]) f[8*i+:8] = k[i];
    return f;
  endfunction

  function string trace_line();
    string s = $sformatf("%0d %0d %0d", rst, en, clr);
    foreach (q[i]) s = {s, $sformatf(" %0d", q[i])};
    foreach (k[i]) s = {s, $sformatf(" %0d", k[i])};
    foreach (obs_acc[i]) s = {s, $sformatf(" %0d", obs_acc[i])};
    return s;
  endfunction
endclass
