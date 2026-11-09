# V and out (128x256) along the bottom edge, read port (top edge) facing
# the logic in the middle; Q and K (64x256) along the top edge, mirrored
# so their read port faces down. Write ports face the die edge, with a
# 40 um channel for their wires.
place_macro -macro_name {u_vmem.u_ram.g_m128.u_sram}   -location {40 40}       -orientation R0
place_macro -macro_name {u_outmem.u_ram.g_m128.u_sram} -location {1320 40}     -orientation R0
place_macro -macro_name {u_qmem.u_ram.g_m64.u_sram}    -location {40 1856.4}   -orientation MX
place_macro -macro_name {u_kmem.u_ram.g_m64.u_sram}    -location {1320 1856.4} -orientation MX
