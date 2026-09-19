// tile_monitor: samples the DUT pins every clock edge and publishes one
// observed transaction per edge: the control/operands applied at edge N
// together with the acc_flat visible after edge N (sampled at edge N+1
// through mon_cb, which reads #1step before the edge, i.e. the post-NBA
// value of edge N). That is exactly the "acc after this edge" the golden
// file records, so scoreboard and coverage both consume the same object.
class tile_monitor extends uvm_monitor;
  `uvm_component_utils(tile_monitor)
  virtual tile_if vif;
  uvm_analysis_port #(tile_seq_item) ap;
  int trace_fd = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    string trace_file;
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tile_if)::get(this, "", "vif", vif))
      `uvm_fatal("MON", "virtual interface not set (uvm_config_db 'vif')")
    // Optional observed-trace file for the post-sim Python check
    // (scripts/gen_tile_uvm_vectors.py --check), same columns as a vector file.
    if ($value$plusargs("TRACE_FILE=%s", trace_file)) begin
      trace_fd = $fopen(trace_file, "w");
      if (trace_fd == 0) `uvm_fatal("MON", $sformatf("cannot write %s", trace_file))
      $fdisplay(trace_fd, "# rst en clr q0..q3 k0..k3 acc00..acc33 (OBSERVED by tb/uvm monitor)");
    end
  endfunction

  task run_phase(uvm_phase phase);
    tile_seq_item pending = null;
    forever begin
      @(vif.mon_cb);
      // Complete the previous edge's transaction with the acc it produced.
      if (pending != null) begin
        for (int i = 0; i < 16; i++) pending.obs_acc[i] = vif.mon_cb.acc_flat[24*i+:24];
        if (trace_fd) $fdisplay(trace_fd, "%s", pending.trace_line());
        ap.write(pending);
      end
      // Capture what is being applied at this edge (edge number = the
      // count sampled before it, plus one).
      pending = tile_seq_item::type_id::create("obs");
      pending.cycle = vif.mon_cb.cycle + 1;
      pending.rst = vif.mon_cb.rst;
      pending.en  = vif.mon_cb.en;
      pending.clr = vif.mon_cb.clr;
      for (int i = 0; i < 4; i++) begin
        pending.q[i] = vif.mon_cb.q_flat[8*i+:8];
        pending.k[i] = vif.mon_cb.k_flat[8*i+:8];
      end
    end
  endtask

  function void final_phase(uvm_phase phase);
    if (trace_fd) $fclose(trace_fd);
  endfunction
endclass
