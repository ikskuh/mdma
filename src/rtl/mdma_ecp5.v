module mdma_ecp5 #(
    parameter CLOCKS_PER_BIT = 104,
    parameter INIT_FILE = ""
) (
    input wire clk, reset, serial_rx,
    input wire [3:0] math_clk,
    output wire serial_tx, halted,
    output wire [3:0] fault
);
    wire [7:0] rx_data, tx_data;
    wire rx_valid, rx_ready, tx_valid, tx_ready;
    (* async_reg = "true" *) reg [1:0] cpu_reset;
    always @(posedge clk or posedge reset)
        if (reset) cpu_reset <= 2'b11; else cpu_reset <= {cpu_reset[0], 1'b0};

    mdma_soc #(.INIT_FILE(INIT_FILE)) soc (
        .clk(clk), .reset(cpu_reset[1]), .math_clk(math_clk),
        .halted(halted), .fault(fault), .ticks(),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );
    mdma_uart #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) uart (
        .clk(clk), .reset(cpu_reset[1]), .serial_rx(serial_rx), .serial_tx(serial_tx),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );
endmodule
