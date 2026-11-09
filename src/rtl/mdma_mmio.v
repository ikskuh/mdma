// Wishbone data-bus device for a byte-oriented USART stream.
module mdma_mmio (
    input wire cyc, stb, we,
    input wire [63:0] adr, wdata,
    input wire [7:0] sel,
    output wire selected, ack,
    output wire [63:0] rdata,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire rx_ready,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready
);
    localparam [63:0] STATUS = 64'h00000000fffffff0, DATA = 64'h00000000fffffff8;
    wire data_register = adr == DATA;
    wire access = cyc && stb && selected;
    assign selected = adr == STATUS || data_register;
    assign rx_ready = access && data_register && !we;
    assign tx_valid = access && data_register && we && sel[0];
    assign tx_data = wdata[7:0];
    assign ack = access && (!data_register || (we ? !sel[0] || tx_ready : rx_valid));
    assign rdata = data_register ? {56'b0, rx_data} : {62'b0, tx_ready, rx_valid};
endmodule
