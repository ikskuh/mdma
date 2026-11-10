module mdma_soc #(
    parameter INIT_FILE = ""
) (
    input wire clk, reset,
    input wire [3:0] math_clk,
    output wire halted,
    output wire [3:0] fault,
    output wire [31:0] ticks,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire rx_ready,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready
);
    wire i_valid, i_ready, d_valid, d_ready, d_write;
    wire [63:0] i_addr, d_addr, d_data, i_result, d_result, mmio_data;
    wire [7:0] d_mask;
    wire mmio, mmio_ready;
    wire i_ram_ready, d_ram_ready, i_ram_reply, d_ram_reply;
    wire i_bounds = |i_addr[63:18];
    wire d_bounds = |d_addr[63:18];
    reg i_error, d_error, mmio_reply;
    reg [63:0] mmio_result;

    assign i_ready = !reset && (i_bounds || i_ram_ready);
    assign d_ready = !reset && (mmio ? mmio_ready : d_bounds || d_ram_ready);
    always @(posedge clk) begin
        i_error <= i_valid && i_ready && i_bounds;
        d_error <= d_valid && d_ready && !mmio && d_bounds;
        mmio_reply <= d_valid && d_ready && mmio;
        if (d_valid && d_ready && mmio)
            mmio_result <= mmio_data;
    end

    mdma_cpu cpu (
        .clk(clk), .reset(reset), .math_clk(math_clk),
        .i_req_valid(i_valid), .i_req_addr(i_addr), .i_req_ready(i_ready),
        .i_rsp_valid(i_ram_reply || i_error), .i_rsp_error(i_error), .i_rsp_data(i_result),
        .d_req_valid(d_valid), .d_req_write(d_write), .d_req_addr(d_addr), .d_req_mask(d_mask),
        .d_req_data(d_data), .d_req_ready(d_ready),
        .d_rsp_valid(d_ram_reply || mmio_reply || d_error), .d_rsp_error(d_error),
        .d_rsp_data(mmio_reply ? mmio_result : d_result),
        .halted(halted), .fault(fault), .ticks(ticks)
    );

    mdma_bram #(.INIT_FILE(INIT_FILE)) bram (
        .clk(clk), .reset(reset),
        .i_valid(i_valid && !i_bounds), .i_addr(i_addr[17:3]), .i_ready(i_ram_ready),
        .i_reply(i_ram_reply), .i_data(i_result),
        .d_valid(d_valid && !mmio && !d_bounds), .d_write(d_write), .d_addr(d_addr[17:3]),
        .d_data(d_data), .d_mask(d_mask), .d_ready(d_ram_ready),
        .d_reply(d_ram_reply), .d_result(d_result)
    );

    mdma_mmio serial_mmio (
        .req_valid(d_valid && !reset), .we(d_write), .adr(d_addr), .wdata(d_data), .sel(d_mask),
        .selected(mmio), .ready(mmio_ready), .rdata(mmio_data),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );
endmodule
