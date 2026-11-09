// Classic Wishbone slave for a word-addressed asynchronous SRAM. A masked
// store uses read-modify-write because the SRAM interface has one WE pin.
module mdma_sram #(
    parameter READ_CLOCKS = 2,
    parameter WRITE_CLOCKS = 2
) (
    input wire clk, reset,
    input wire cyc, stb, we,
    input wire [31:0] word_address,
    input wire [63:0] wdata,
    input wire [7:0] sel,
    output wire ack,
    output reg [63:0] rdata,
    output reg [31:0] sram_a,
    inout wire [63:0] sram_d,
    output wire sram_cs_n, sram_oe_n, sram_we_n
);
    localparam IDLE = 0, READ = 1, SETUP = 2, WRITE = 3, HOLD = 4, REPLY = 5;
    localparam MAX_WAIT = READ_CLOCKS > WRITE_CLOCKS ? READ_CLOCKS : WRITE_CLOCKS;
    localparam WAIT_BITS = MAX_WAIT > 1 ? $clog2(MAX_WAIT) : 1;
    reg [2:0] state;
    reg [WAIT_BITS-1:0] remaining;
    reg [7:0] lanes;
    reg writing;
    reg [63:0] data;
    integer i;

    assign ack = state == REPLY && cyc && stb;
    assign sram_cs_n = !(state == READ || state == SETUP || state == WRITE || state == HOLD);
    assign sram_oe_n = state != READ;
    assign sram_we_n = state != WRITE;
    assign sram_d = state == SETUP || state == WRITE || state == HOLD ? data : 64'bz;

    always @(posedge clk) begin
        if (reset)
            state <= IDLE;
        else begin
            case (state)
                IDLE: if (cyc && stb) begin
                    sram_a <= word_address;
                    lanes <= sel;
                    data <= wdata;
                    writing <= we;
                    remaining <= READ_CLOCKS - 1;
                    if (!we || (sel != 0 && sel != 8'hff))
                        state <= READ;
                    else
                        state <= sel == 0 ? REPLY : SETUP;
                end
                READ: if (remaining != 0)
                    remaining <= remaining - 1'b1;
                else begin
                    rdata <= sram_d;
                    if (writing)
                        for (i = 0; i < 8; i = i + 1)
                            if (!lanes[i])
                                data[i*8 +: 8] <= sram_d[i*8 +: 8];
                    state <= writing ? SETUP : REPLY;
                end
                SETUP: begin
                    remaining <= WRITE_CLOCKS - 1;
                    state <= WRITE;
                end
                WRITE: if (remaining == 0)
                    state <= HOLD;
                else
                    remaining <= remaining - 1'b1;
                HOLD: state <= REPLY;
                REPLY: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
