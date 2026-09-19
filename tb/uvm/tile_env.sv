// tile_env: agent + scoreboard + coverage, wired through analysis ports.
class tile_env extends uvm_env;
  `uvm_component_utils(tile_env)
  tile_agent agent;
  tile_scoreboard sb;
  tile_coverage cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = tile_agent::type_id::create("agent", this);
    sb    = tile_scoreboard::type_id::create("sb", this);
    cov   = tile_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.driven_ap.connect(sb.driven_fifo.analysis_export);
    agent.mon.ap.connect(sb.observed_fifo.analysis_export);
    agent.mon.ap.connect(cov.analysis_export);
  endfunction
endclass
