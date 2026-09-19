// tile_driver: one seq_item per clock edge onto tile_if.drv_cb. The
// item's control/operands are driven for exactly one cycle; the sequence
// decides what the next cycle holds (there is no protocol handshake in the
// tile, docs/uarch.md 8.1: "the tile contains no counters, no FSM"). Every
// driven item is also published on driven_ap so the scoreboard can pair
// it, in order, with the monitor's observation of the same edge.
class tile_driver extends uvm_driver #(tile_seq_item);
  `uvm_component_utils(tile_driver)
  virtual tile_if vif;
  uvm_analysis_port #(tile_seq_item) driven_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    driven_ap = new("driven_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tile_if)::get(this, "", "vif", vif))
      `uvm_fatal("DRV", "virtual interface not set (uvm_config_db 'vif')")
  endfunction

  task run_phase(uvm_phase phase);
    // Idle defaults before the first item.
    vif.drv_cb.rst    <= 1'b1;
    vif.drv_cb.en     <= 1'b0;
    vif.drv_cb.clr    <= 1'b0;
    vif.drv_cb.q_flat <= '0;
    vif.drv_cb.k_flat <= '0;
    forever begin
      seq_item_port.get_next_item(req);
      @(vif.drv_cb);
      // Driven now (after edge N), applied at edge N+1; drv_cb.cycle reads
      // N-1 at this event, so the applied edge is drv_cb.cycle + 2.
      req.cycle = vif.drv_cb.cycle + 2;
      vif.drv_cb.rst    <= req.rst;
      vif.drv_cb.en     <= req.en;
      vif.drv_cb.clr    <= req.clr;
      vif.drv_cb.q_flat <= req.q_flat();
      vif.drv_cb.k_flat <= req.k_flat();
      driven_ap.write(req);
      seq_item_port.item_done();
    end
  endtask
endclass
