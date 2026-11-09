// tile_replay_sequence: replays a golden vector file from
//   scripts/gen_tile_uvm_vectors.py --emit, with expected acc per edge.
// tile_random_sequence: constrained-random whole dot products (clr on d=0,
//   16 enabled beats, bubbles, clears); checked post-sim by
//   `make -C tb/uvm check`.
typedef uvm_sequencer #(tile_seq_item) tile_sequencer;

class tile_replay_sequence extends uvm_sequence #(tile_seq_item);
  `uvm_object_utils(tile_replay_sequence)
  string vector_file = "";

  function new(string name = "tile_replay_sequence");
    super.new(name);
  endfunction

  task body();
    int fd, n = 0;
    string line;
    tile_seq_item it;
    int r, e, c, qv[4], kv[4], av[16];
    if (vector_file == "" && !$value$plusargs("VECTOR_FILE=%s", vector_file))
      `uvm_fatal("REPLAY", "no vector file: set +VECTOR_FILE=<path>")
    fd = $fopen(vector_file, "r");
    if (fd == 0) `uvm_fatal("REPLAY", $sformatf("cannot open %s", vector_file))
    while (!$feof(fd)) begin
      if ($fgets(line, fd) == 0) break;
      if (line.len() == 0 || line[0] == "#" || line[0] == "\n") continue;
      if ($sscanf(line, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                  r, e, c, qv[0], qv[1], qv[2], qv[3], kv[0], kv[1], kv[2], kv[3],
                  av[0], av[1], av[2], av[3], av[4], av[5], av[6], av[7],
                  av[8], av[9], av[10], av[11], av[12], av[13], av[14], av[15]) != 27) begin
        `uvm_fatal("REPLAY", $sformatf("%s: bad line: %s", vector_file, line))
      end
      it = tile_seq_item::type_id::create($sformatf("vec%0d", n));
      start_item(it);
      it.rst = r[0];
      it.en  = e[0];
      it.clr = c[0];
      foreach (qv[i]) it.q[i] = qv[i];
      foreach (kv[i]) it.k[i] = kv[i];
      it.has_expected = 1;
      foreach (av[i]) it.exp_acc[i] = av[i];
      finish_item(it);
      n++;
    end
    $fclose(fd);
    `uvm_info("REPLAY", $sformatf("replayed %0d cycles from %s", n, vector_file), UVM_LOW)
  endtask
endclass


class tile_random_sequence extends uvm_sequence #(tile_seq_item);
  `uvm_object_utils(tile_random_sequence)
  int unsigned num_dots = 100;

  function new(string name = "tile_random_sequence");
    super.new(name);
  endfunction

  // One item with fixed control and randomized operands. Argument names
  // differ from the fields so no local:: is needed (Verilator rejects it).
  task drive(bit r_rst, bit r_en, bit r_clr);
    tile_seq_item it = tile_seq_item::type_id::create("rnd");
    // c_ctrl off: Verilator 5.053 reports dist plus == on one variable as
    // unsatisfiable.
    it.c_ctrl.constraint_mode(0);
    start_item(it);
    if (!it.randomize() with { rst == r_rst; en == r_en; clr == r_clr; })
      `uvm_fatal("RND", "randomize failed")
    finish_item(it);
  endtask

  task body();
    int unsigned holds;
    drive(1, 0, 0);
    drive(1, 0, 0);
    drive(0, 0, 0);
    repeat (num_dots) begin
      // D=16 dot product with occasional hold bubbles
      for (int d = 0; d < 16; d++) begin
        if (d > 0 && ($urandom_range(0, 99) < 8)) drive(0, 0, 0);
        drive(0, 1, d == 0);
      end
      case ($urandom_range(0, 9))
        0: drive(0, 0, 1);                 // clr without en: clear
        1: drive(1, 0, 0);                 // reset between dots
        2, 3: begin                        // idle holds
          holds = $urandom_range(1, 3);
          repeat (holds) drive(0, 0, 0);
        end
        default: ;                         // back to back
      endcase
    end
    drive(0, 0, 0);
  endtask
endclass
