// tile_uvm_pkg: the matmul_tile UVM environment, files in dependency order.
package tile_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "tile_seq_item.sv"
  `include "tile_sequence.sv"
  `include "tile_driver.sv"
  `include "tile_monitor.sv"
  `include "tile_agent.sv"
  `include "tile_scoreboard.sv"
  `include "tile_coverage.sv"
  `include "tile_env.sv"
  `include "tile_test.sv"
endpackage
