// Two independently indexed lookups per clock: instruction and optional
// extended immediate. Refill one word at a time over Wishbone.
module mdma_icache #(
    parameter SET_BITS = 3,
    parameter ADDRESS_BITS = 64
) (
    input wire clk, reset, request, accept, invalidate,
    input wire [ADDRESS_BITS-1:0] address, invalidate_address,
    output wire ready, error,
    output wire [63:0] word, immediate,
    output wire [29:0] sinks,
    output wire wb_cyc, wb_stb,
    output wire [ADDRESS_BITS-1:0] wb_adr,
    input wire [63:0] wb_dat,
    input wire wb_ack, wb_err
);
    localparam SETS = 1 << SET_BITS;
    localparam TAG_BITS = ADDRESS_BITS - 3 - SET_BITS;
    reg [SETS-1:0] valid0, valid1, victim;
    reg [TAG_BITS+93:0] way0 [0:SETS-1], way1 [0:SETS-1];
    wire [ADDRESS_BITS-1:0] immediate_address = address + 4'd8;
    wire [SET_BITS-1:0] index0 = address[3 +: SET_BITS];
    wire [SET_BITS-1:0] index1 = immediate_address[3 +: SET_BITS];
    wire [SET_BITS-1:0] invalidate_index = invalidate_address[3 +: SET_BITS];
    wire [TAG_BITS-1:0] tag0 = address[ADDRESS_BITS-1:3+SET_BITS];
    wire [TAG_BITS-1:0] tag1 = immediate_address[ADDRESS_BITS-1:3+SET_BITS];
    wire use_word = !(invalidate && invalidate_index == index0);
    wire use_immediate = !(invalidate && invalidate_index == index1);
    wire hit00 = use_word && valid0[index0] && way0[index0][TAG_BITS+93:94] == tag0;
    wire hit01 = use_word && valid1[index0] && way1[index0][TAG_BITS+93:94] == tag0;
    wire hit10 = use_immediate && valid0[index1] && way0[index1][TAG_BITS+93:94] == tag1;
    wire hit11 = use_immediate && valid1[index1] && way1[index1][TAG_BITS+93:94] == tag1;
    function [29:0] decode_sinks(input [63:0] instruction);
        integer slot;
        reg [8:0] sum;
        begin
            sum = 0;
            for (slot = 0; slot < 5; slot = slot + 1) begin
                sum = sum + {3'b0, instruction[slot*12+6 +: 6]} + (slot != 0);
                decode_sinks[slot*6 +: 6] = sum >= 63 ? 6'd63 : sum[5:0];
            end
        end
    endfunction

    wire hit_word = hit00 || hit01;
    wire extended = word[61:60] == 1;
    reg busy;
    reg [ADDRESS_BITS-1:0] refill_address;
    wire [SET_BITS-1:0] refill_index = refill_address[3 +: SET_BITS];
    wire [TAG_BITS-1:0] refill_tag = refill_address[ADDRESS_BITS-1:3+SET_BITS];
    wire refill_way = valid0[refill_index] && (!valid1[refill_index] || victim[refill_index]);
    // A data write may complete during an instruction refill. Discard that
    // response if it might have sampled memory before the store.
    reg refill_invalidated;
    wire invalidates_refill = invalidate && invalidate_index == refill_index;

    assign sinks = hit00 ? way0[index0][93:64] : way1[index0][93:64];
    assign word = hit00 ? way0[index0][63:0] : way1[index0][63:0];
    assign immediate = hit10 ? way0[index1][63:0] : way1[index1][63:0];
    assign ready = hit_word && (!extended || hit10 || hit11);
    assign wb_cyc = busy;
    assign wb_stb = busy;
    assign wb_adr = refill_address;
    assign error = busy && wb_err;

    always @(posedge clk) begin
        if (reset) begin
            valid0 <= 0;
            valid1 <= 0;
            victim <= 0;
            busy <= 0;
            refill_invalidated <= 0;
        end else begin
            if (invalidate) begin
                valid0[invalidate_index] <= 0;
                valid1[invalidate_index] <= 0;
            end
            if (busy && invalidates_refill)
                refill_invalidated <= 1;
            if (busy && (wb_ack || wb_err)) begin
                busy <= 0;
                if (wb_ack && !wb_err && !invalidates_refill && !refill_invalidated) begin
                    if (refill_way) begin
                        way1[refill_index] <= {refill_tag, decode_sinks(wb_dat), wb_dat};
                        valid1[refill_index] <= 1;
                    end else begin
                        way0[refill_index] <= {refill_tag, decode_sinks(wb_dat), wb_dat};
                        valid0[refill_index] <= 1;
                    end
                    victim[refill_index] <= !refill_way;
                end
            end else if (!busy && request && !ready) begin
                refill_address <= hit_word ? immediate_address : address;
                refill_invalidated <= 0;
                busy <= 1;
            end
            if (accept) begin
                victim[index0] <= hit00;
                if (extended)
                    victim[index1] <= hit10;
            end
        end
    end
endmodule
