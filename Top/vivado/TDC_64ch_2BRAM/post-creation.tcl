# Hog post-creation hook: enable the ZynqMP PS-PCIe controller as an ENDPOINT.
#
# Why PS-PCIe and not PL/XDMA: on the KrIO Rev 4 carrier the PCIe x4 connector J4
# is wired to the PS-GTR lanes (netlist: GTR_DP0..3_C2M -> J4.A16/A17/A21/A22/
# A25/A26/A29/A30, plus GTR_REFCLK0_C2M).  There are zero GTH nets on J4, so the
# PL transceivers are not an option without a board respin.  This is intentional:
# the design buffers acquisition data in the 4 GB PS DDR4 before DMAing to the
# host, which is what the PS controller is good at.
#
# Ceiling to be aware of: the ZynqMP PS-PCIe block is x4 Gen2 max (~2 GB/s
# theoretical, ~1.6 GB/s realistic sustained).  Burst capture is bounded by the
# PS DDR4 buffer, not by this link.
#
# Host-side note: the Linux driver in the stock device tree (xlnx,nwl-pcie-2.11)
# is the ROOT PORT driver and is the wrong one for an endpoint.  On the device
# side use AMD's PS-PCIe endpoint DMA support (Xilinx/zynqmp-pspcie-epdma).

# The block design is not open at post-creation time; open it before touching cells.
set bd [get_files -quiet *design_64ch_2BRAM.bd]
if {$bd eq ""} {
    puts "post-creation.tcl: WARNING - design_64ch_2BRAM.bd not found, skipping PCIe config"
    return
}
if {[catch {open_bd_design $bd} err]} {
    puts "post-creation.tcl: WARNING - could not open BD ($err), skipping PCIe config"
    return
}

set ps [get_bd_cells -quiet zynq_ultra_ps_e_0]
if {$ps eq ""} {
    puts "post-creation.tcl: WARNING - zynq_ultra_ps_e_0 not found, skipping PCIe config"
    return
}

puts "post-creation.tcl: enabling PS-PCIe endpoint (x4 Gen2) on $ps"

set_property -dict [list \
    CONFIG.PSU__PCIE__PERIPHERAL__ENABLE          {1} \
    CONFIG.PSU__PCIE__PERIPHERAL__ENDPOINT_ENABLE {1} \
    CONFIG.PSU__PCIE__PERIPHERAL__ROOTPORT_ENABLE {0} \
    CONFIG.PSU__PCIE__DEVICE_PORT_TYPE            {Endpoint Device} \
    CONFIG.PSU__PCIE__MAXIMUM_LINK_WIDTH          {x4} \
    CONFIG.PSU__PCIE__LINK_SPEED                  {5.0 Gb/s} \
    CONFIG.PSU__PCIE__LANE0__ENABLE               {1} \
    CONFIG.PSU__PCIE__LANE1__ENABLE               {1} \
    CONFIG.PSU__PCIE__LANE2__ENABLE               {1} \
    CONFIG.PSU__PCIE__LANE3__ENABLE               {1} \
    CONFIG.PSU__PCIE__REF_CLK_SEL                 {Ref Clk0} \
    CONFIG.PSU__PCIE__REF_CLK_FREQ                {100} \
    CONFIG.PSU__PCIE__CLASS_CODE_BASE             {0x11} \
    CONFIG.PSU__PCIE__CLASS_CODE_SUB              {0x80} \
    CONFIG.PSU__PCIE__CLASS_CODE_INTERFACE        {0x00} \
    CONFIG.PSU__PCIE__BAR0_ENABLE                 {1} \
    CONFIG.PSU__PCIE__BAR0_64BIT                  {1} \
    CONFIG.PSU__PCIE__BAR0_PREFETCHABLE           {1} \
] $ps

# Class code 0x118000 = Data acquisition / signal processing controller,
# which is the correct PCI class for a DAQ card.

validate_bd_design -quiet
save_bd_design
puts "post-creation.tcl: PS-PCIe endpoint configured"
