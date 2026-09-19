// tile_scoreboard: pairs each DRIVEN item (from the driver's analysis port,
// carrying the golden expected acc when the item came from a vector file)
// with the OBSERVED transaction the monitor publishes for the same edge,
// in order, and compares.
//
//   Replay test: exp_acc came from the Python mirror
//   (scripts/gen_tile_uvm_vectors.py). Any of the 16 accumulators
//   differing is an error; the test fails (uvm_fatal at the end of the run
//   with a nonzero exit, which `make uvm-bug-proof` relies on).
//
//   Random test (has_expected = 0): only the CONTROL contract is checked
//   here (rst -> 0, clr && !en -> 0, !clr && !en -> hold); the arithmetic is
//   checked after the run by the Python mirror over the monitor's trace
//   file. There is deliberately no SystemVerilog MAC model in this
//   environment.
class tile_scoreboard extends uvm_component;
  `uvm_component_utils(tile_scoreboard)
  uvm_tlm_analysis_fifo #(tile_seq_item) driven_fifo;
  uvm_tlm_analysis_fifo #(tile_seq_item) observed_fifo;
  int unsigned n_checked = 0, n_golden = 0, n_errors = 0;
  bit signed [23:0] prev_acc[16];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    driven_fifo   = new("driven_fifo", this);
    observed_fifo = new("observed_fifo", this);
  endfunction

  task run_phase(uvm_phase phase);
    tile_seq_item drv, obs;
    forever begin
      driven_fifo.get(drv);
      // Observations of edges nobody drove (idle defaults before the first
      // item) are dropped; a driven edge with no observation is an error.
      do begin
        observed_fifo.get(obs);
        if (obs.cycle > drv.cycle) begin
          n_errors++;
          `uvm_error("SB", $sformatf("driven edge %0d was never observed (next observation is edge %0d)", drv.cycle, obs.cycle))
        end
      end while (obs.cycle < drv.cycle);
      n_checked++;
      // The observed control must be what was driven (interface sanity).
      if (obs.rst != drv.rst || obs.en != drv.en || obs.clr != drv.clr) begin
        n_errors++;
        `uvm_error("SB", $sformatf("cycle %0d: driven rst/en/clr=%0d/%0d/%0d but observed %0d/%0d/%0d",
                   n_checked, drv.rst, drv.en, drv.clr, obs.rst, obs.en, obs.clr))
      end
      if (drv.has_expected) begin
        n_golden++;
        for (int i = 0; i < 16; i++) begin
          if (obs.obs_acc[i] !== drv.exp_acc[i]) begin
            n_errors++;
            if (n_errors <= 20)
              `uvm_error("SB", $sformatf("cycle %0d acc(%0d,%0d): dut=%0d golden=%0d (rst=%0d en=%0d clr=%0d q=%p k=%p)",
                         n_checked, i / 4, i % 4, obs.obs_acc[i], drv.exp_acc[i],
                         drv.rst, drv.en, drv.clr, drv.q, drv.k))
          end
        end
      end else begin
        // Control-contract checks only (docs/uarch.md 8.1 table).
        for (int i = 0; i < 16; i++) begin
          if (drv.rst && obs.obs_acc[i] != 0) begin
            n_errors++;
            `uvm_error("SB", $sformatf("cycle %0d: rst but acc(%0d,%0d)=%0d", n_checked, i / 4, i % 4, obs.obs_acc[i]))
          end else if (!drv.rst && drv.clr && !drv.en && obs.obs_acc[i] != 0) begin
            n_errors++;
            `uvm_error("SB", $sformatf("cycle %0d: clr&&!en but acc(%0d,%0d)=%0d", n_checked, i / 4, i % 4, obs.obs_acc[i]))
          end else if (!drv.rst && !drv.clr && !drv.en && obs.obs_acc[i] != prev_acc[i]) begin
            n_errors++;
            `uvm_error("SB", $sformatf("cycle %0d: hold violated acc(%0d,%0d) %0d -> %0d", n_checked, i / 4, i % 4, prev_acc[i], obs.obs_acc[i]))
          end
        end
      end
      prev_acc = obs.obs_acc;
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("checked %0d cycles (%0d against golden vectors), %0d errors",
              n_checked, n_golden, n_errors), UVM_LOW)
    if (n_checked == 0) `uvm_fatal("SB", "no cycles checked: the environment did not run")
    if (n_errors != 0) `uvm_fatal("SB", $sformatf("%0d scoreboard errors", n_errors))
  endfunction
endclass
