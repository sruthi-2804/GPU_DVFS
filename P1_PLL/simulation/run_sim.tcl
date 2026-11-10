# ---------------------------------------------------------------------------
# Standalone behavioral simulation of the P1 PLL controller.
#
# Usage, from the simulation/ directory:
#     vivado -mode batch -source run_sim.tcl
#
# Creates a throwaway Vivado project in ./work, runs the testbench to
# completion and exits. Delete ./work to clean up.
# ---------------------------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]
set block_root [file dirname $script_dir]

create_project -force p1_pll_sim [file join $script_dir work]

add_files -norecurse [file join $block_root rtl p1_pll_controller.v]
add_files -fileset sim_1 -norecurse [file join $block_root tb tb_p1_pll_controller.v]

set_property top tb_p1_pll_controller [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
exit
