`timescale 1ns / 1ps
// tb_top: top level of the matmul_tile UVM environment. Instantiates the
// interface and the DUT, hands the interface to the environment through
// uvm_config_db, and runs run_test(). The test name comes from
// +UVM_TESTNAME (tile_replay_test or tile_random_test, tb/uvm/tile_test.sv).
//
// Exit status: the scoreboard raises uvm_fatal on any error; as a second
// line, final_phase here counts UVM_ERROR/UVM_FATAL reports and calls
// $fatal so the simulator returns nonzero even if a future edit removed the
// scoreboard's fatal. `make -C tb/uvm bug-proof` depends on this.
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

  // UVM_NO_DPI builds (Verilator) cannot read +UVM_TESTNAME inside run_test(), so
  // read it here; xsim and any DPI build behave identically.
  string tn;
  initial begin
    uvm_config_db#(virtual tile_if)::set(null, "*", "vif", tif);
    if ($value$plusargs("UVM_TESTNAME=%s", tn)) run_test(tn);
    else run_test();
  end

  final begin
    uvm_report_server srv;
    int errs;
    // declaration and assignment are separate on purpose: an initializer here can be
    // evaluated once at time 0 (static-variable rule) and then never sees the errors.
    srv = uvm_report_server::get_server();
    errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL);
    if (errs != 0) $fatal(1, "tb_top: %0d UVM errors/fatals", errs);
    else $display("tb_top: UVM run clean (0 errors)");
  end
endmodule
