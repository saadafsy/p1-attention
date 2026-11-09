`timescale 1ns / 1ps
// tb_top: matmul_tile UVM top. Test from +UVM_TESTNAME (tile_replay_test or
// tile_random_test). The final block turns any UVM_ERROR/UVM_FATAL into
// $fatal so the simulator exits nonzero; `make -C tb/uvm bug-proof` needs it.
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import tile_uvm_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;  // 100 MHz, the same period the cocotb TBs use

  tile_if tif (.clk(clk));

  matmul_tile dut (
      .clk     (clk),
      .rst     (tif.rst),
      .en      (tif.en),
      .clr     (tif.clr),
      .q_flat  (tif.q_flat),
      .k_flat  (tif.k_flat),
      .acc_flat(tif.acc_flat)
  );

  // UVM_NO_DPI builds (Verilator) cannot read +UVM_TESTNAME in run_test().
  string tn;
  initial begin
    uvm_config_db#(virtual tile_if)::set(null, "*", "vif", tif);
    if ($value$plusargs("UVM_TESTNAME=%s", tn)) run_test(tn);
    else run_test();
  end

  final begin
    uvm_report_server srv;
    int errs;
    // Assigned separately: a static initializer would run at time 0.
    srv = uvm_report_server::get_server();
    errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL);
    if (errs != 0) $fatal(1, "tb_top: %0d UVM errors/fatals", errs);
    else $display("tb_top: UVM run clean (0 errors)");
  end
endmodule
