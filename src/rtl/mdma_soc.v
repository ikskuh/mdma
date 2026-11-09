// UART MMIO stays on the CPU clock. The two SRAM masters meet only after
// crossing into the memory domain, where the arbiter holds the grant to ACK.
module mdma_soc (
    input wire clk, mem_clk, reset, mem_reset,
    input wire [3:0] math_clk,
    output wire halted,
    output wire [3:0] fault,
    output wire [31:0] ticks,
    output wire ram_cyc, ram_stb, ram_we,
    output wire [31:0] ram_word_address,
    output wire [63:0] ram_wdata,
    output wire [7:0] ram_sel,
    input wire ram_ack,
    input wire [63:0] ram_rdata,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire rx_ready,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready
);
    wire i_cyc, i_stb, d_cyc, d_stb, d_we;
    wire [63:0] i_adr, d_adr, d_wdata, mmio_rdata, i_sram_data, d_sram_data;
    wire [7:0] d_sel;
    wire mmio, mmio_ack, i_sram_ack, d_sram_ack, d_sram_complete;
    wire i_bounds = |i_adr[63:35];
    wire d_bounds = |d_adr[63:35];

    mdma_cpu cpu (
        .clk(clk), .reset(reset), .invalidate_icache(d_sram_complete && d_we && |d_sel), .math_clk(math_clk),
        .i_wb_cyc(i_cyc), .i_wb_stb(i_stb), .i_wb_adr(i_adr),
        .i_wb_dat(i_sram_data), .i_wb_ack(i_sram_ack), .i_wb_err(i_cyc && i_bounds),
        .d_wb_cyc(d_cyc), .d_wb_stb(d_stb), .d_wb_we(d_we), .d_wb_adr(d_adr),
        .d_wb_sel(d_sel), .d_wb_dat_o(d_wdata), .d_wb_dat_i(mmio ? mmio_rdata : d_sram_data),
        .d_wb_ack(mmio ? mmio_ack : d_sram_ack), .d_wb_err(d_cyc && !mmio && d_bounds),
        .halted(halted), .fault(fault), .ticks(ticks)
    );

    wire i_pending, d_pending, d_mem_we;
    wire [31:0] i_mem_address, d_mem_address;
    wire [7:0] d_mem_sel;
    wire [63:0] d_mem_data;
    reg busy, owner_data;
    wire grant_data = busy ? owner_data : d_pending;

    mdma_wb_cdc instruction (
        .cpu_clk(clk), .mem_clk(mem_clk), .reset(reset), .mem_reset(mem_reset),
        .request(i_cyc && i_stb && !i_bounds), .payload(i_adr[34:3]),
        .ack(i_sram_ack), .complete(), .response(i_sram_data),
        .mem_request(i_pending), .mem_payload(i_mem_address),
        .mem_ack(ram_ack && !grant_data), .mem_response(ram_rdata)
    );
    mdma_wb_cdc #(.REQUEST_WIDTH(105)) data (
        .cpu_clk(clk), .mem_clk(mem_clk), .reset(reset), .mem_reset(mem_reset),
        .request(d_cyc && d_stb && !mmio && !d_bounds), .payload({d_we, d_adr[34:3], d_sel, d_wdata}),
        .ack(d_sram_ack), .complete(d_sram_complete), .response(d_sram_data),
        .mem_request(d_pending), .mem_payload({d_mem_we, d_mem_address, d_mem_sel, d_mem_data}),
        .mem_ack(ram_ack && grant_data), .mem_response(ram_rdata)
    );

    assign ram_cyc = !mem_reset && (grant_data ? d_pending : i_pending);
    assign ram_stb = ram_cyc;
    assign ram_we = grant_data && d_mem_we;
    assign ram_word_address = grant_data ? d_mem_address : i_mem_address;
    assign ram_sel = grant_data ? d_mem_sel : 8'hff;
    assign ram_wdata = d_mem_data;

    always @(posedge mem_clk) begin
        if (mem_reset || ram_ack)
            busy <= 0;
        else if (!busy && ram_cyc) begin
            busy <= 1;
            owner_data <= grant_data;
        end
    end

    mdma_mmio serial_mmio (
        .cyc(d_cyc), .stb(d_stb), .we(d_we), .adr(d_adr), .wdata(d_wdata), .sel(d_sel),
        .selected(mmio), .ack(mmio_ack), .rdata(mmio_rdata),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );
endmodule
