export DESIGN_NICKNAME = online_softmax
export DESIGN_NAME     = online_softmax_pipe1
export PLATFORM        = sky130hd

export VERILOG_FILES = /work/rtl/exp_lut_1p.sv /work/rtl/online_softmax.sv \
                       /work/pd/online_softmax/online_softmax_pipe1.sv
export VERILOG_INCLUDE_DIRS = /work
export SDC_FILE      = /work/pd/online_softmax/constraint.sdc

export CORE_UTILIZATION = 40
export PLACE_DENSITY    = 0.60
# Repair to 80% of the slew/cap limits so the post-route values stay inside them.
export SLEW_MARGIN = 20
export CAP_MARGIN  = 20
