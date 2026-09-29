// Tests for the matmul_tile UVM environment.
//
//   tile_replay_test  (+UVM_TESTNAME=tile_replay_test +VECTOR_FILE=...)
//     Golden path: replays a Python-generated vector file; the scoreboard
//     compares every accumulator on every edge against the Python mirror.
//   tile_random_test  (+UVM_TESTNAME=tile_random_test [+NUM_DOTS=n] +TRACE_FILE=...)
//     SV constrained-random stimulus; in-sim only the control contract is
//     checked, the arithmetic is checked post-sim by
//     `python3 scripts/gen_tile_uvm_vectors.py --check <TRACE_FILE>`.
//
// Both end with a scoreboard report_phase that raises uvm_fatal on any
// error, so the simulator exits nonzero; tb_top additionally checks the
// UVM error count and calls $fatal. `make -C tb/uvm bug-proof` relies on
// exactly that to prove the environment catches the injected mac_unit bug.
class tile_base_test extends uvm_test;
  `uvm_component_utils(tile_base_test)
  tile_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = tile_env::type_id::create("env", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_root::get().print_topology();
  endfunction
endclass


class tile_replay_test extends tile_base_test;
  `uvm_component_utils(tile_replay_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tile_replay_sequence seq = tile_replay_sequence::type_id::create("seq");
    phase.raise_objection(this);
    seq.start(env.agent.sqr);
    // let the last edge be observed and scored
    repeat (4) @(env.agent.drv.vif.drv_cb);
    phase.drop_objection(this);
  endtask
endclass


class tile_random_test extends tile_base_test;
  `uvm_component_utils(tile_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    int n;
    tile_random_sequence seq = tile_random_sequence::type_id::create("seq");
    if ($value$plusargs("NUM_DOTS=%d", n)) seq.num_dots = n;
    phase.raise_objection(this);
    seq.start(env.agent.sqr);
    repeat (4) @(env.agent.drv.vif.drv_cb);
    phase.drop_objection(this);
  endtask
endclass
