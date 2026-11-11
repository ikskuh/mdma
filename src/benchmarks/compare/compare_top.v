module mdma_compare_top #(
    parameter INIT_FILE = ""
) (
    input wire clk, reset, serial_rx,
    output wire serial_tx, halted,
    output wire [3:0] fault
);
    mdma_ecp5 #(.INIT_FILE(INIT_FILE)) board (
        .clk(clk), .reset(reset), .math_clk({4{clk}}),
        .serial_rx(serial_rx), .serial_tx(serial_tx), .halted(halted), .fault(fault)
    );
endmodule
