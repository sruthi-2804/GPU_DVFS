#!/bin/sh
# Command-line XSim flow, no Vivado project required.
# Run from the simulation/ directory with Vivado's bin on PATH.
set -e
xvlog --relax ../rtl/p1_pll_controller.v ../tb/tb_p1_pll_controller.v
xelab --debug typical --relax -top tb_p1_pll_controller -snapshot tb_p1_pll_sim
xsim tb_p1_pll_sim -runall
