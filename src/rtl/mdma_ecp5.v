module mdma_ecp5 #(
    parameter CLOCKS_PER_BIT = 104,
    parameter SRAM_READ_CLOCKS = 2,
    parameter SRAM_WRITE_CLOCKS = 2
) (
    input wire clk, mem_clk, reset, serial_rx,
    input wire [3:0] math_clk,
    output wire serial_tx, halted,
    output wire [3:0] fault,
    output wire [31:0] sram_a,
    inout wire [63:0] sram_d,
    output wire sram_cs_n, sram_oe_n, sram_we_n
);
    wire cyc, stb, we, ack;
    wire [31:0] address;
    wire [63:0] wdata, rdata;
    wire [7:0] sel, rx_data, tx_data;
    wire rx_valid, rx_ready, tx_valid, tx_ready;
    (* async_reg = "true" *) reg [1:0] cpu_reset, mem_reset;
    always @(posedge clk or posedge reset)
        if (reset) cpu_reset <= 2'b11; else cpu_reset <= {cpu_reset[0], 1'b0};
    always @(posedge mem_clk or posedge reset)
        if (reset) mem_reset <= 2'b11; else mem_reset <= {mem_reset[0], 1'b0};

    mdma_soc soc (
        .clk(clk), .mem_clk(mem_clk), .reset(cpu_reset[1]), .mem_reset(mem_reset[1]),
        .math_clk(math_clk), .halted(halted), .fault(fault), .ticks(),
        .ram_cyc(cyc), .ram_stb(stb), .ram_we(we), .ram_word_address(address),
        .ram_wdata(wdata), .ram_sel(sel), .ram_ack(ack), .ram_rdata(rdata),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );
    mdma_sram #(.READ_CLOCKS(SRAM_READ_CLOCKS), .WRITE_CLOCKS(SRAM_WRITE_CLOCKS)) sram (
        .clk(mem_clk), .reset(mem_reset[1]), .cyc(cyc), .stb(stb), .we(we), .word_address(address),
        .wdata(wdata), .sel(sel), .ack(ack), .rdata(rdata),
        .sram_a(sram_a), .sram_d(sram_d), .sram_cs_n(sram_cs_n), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n)
    );
    mdma_uart #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) uart (
        .clk(clk), .reset(cpu_reset[1]), .serial_rx(serial_rx), .serial_tx(serial_tx),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );
endmodule
