// tile_agent: sequencer + driver + monitor for tile_if. The driver also
// publishes every driven item (with its golden expectation, when it has
// one) so the scoreboard can pair driven and observed edges in order.
class tile_agent extends uvm_agent;
  `uvm_component_utils(tile_agent)
  tile_sequencer sqr;
  tile_driver drv;
  tile_monitor mon;
  uvm_analysis_port #(tile_seq_item) driven_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = tile_sequencer::type_id::create("sqr", this);
    drv = tile_driver::type_id::create("drv", this);
    mon = tile_monitor::type_id::create("mon", this);
    driven_ap = new("driven_ap", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    drv.driven_ap.connect(driven_ap);
  endfunction
endclass
