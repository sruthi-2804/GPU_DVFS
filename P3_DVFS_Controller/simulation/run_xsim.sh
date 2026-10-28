#!/bin/sh
# Command-line XSim flow, no Vivado project required.
# Run from the simulation/ directory with Vivado's bin on PATH.
set -e
xvlog --relax ../rtl/p3_dvfs_controller.v ../tb/p3_dvfs_tb.v
xelab --debug typical --relax -top p3_dvfs_tb -snapshot p3_dvfs_tb_sim
xsim p3_dvfs_tb_sim -runall
