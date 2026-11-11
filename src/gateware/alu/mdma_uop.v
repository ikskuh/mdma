module mdma_uop #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_in_data,
    input wire i_in_valid,
    output wire i_in_take,
    output wire [63:0] o_neg_data,
    output wire o_neg_valid,
    input wire o_neg_take,
    output wire [63:0] o_not_data,
    output wire o_not_valid,
    input wire o_not_take,
    output wire [63:0] o_bsw_data,
    output wire o_bsw_valid,
    input wire o_bsw_take
);
    wire [63:0] result_neg = -i_in_data;
    wire [63:0] result_not = ~i_in_data;
    wire [63:0] result_bsw;

    for (genvar byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin : reverse_bytes
        assign result_bsw[8*byte_index +: 8] = i_in_data[8*(7-byte_index) +: 8];
    end

    wire accept;
    assign i_in_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(3)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_in_valid),
        .operands_take(accept),
        .result_data({result_neg, result_not, result_bsw}),
        .result_mask(3'b111),
        .take({o_neg_take, o_not_take, o_bsw_take}),
        .data({o_neg_data, o_not_data, o_bsw_data}),
        .valid({o_neg_valid, o_not_valid, o_bsw_valid})
    );
endmodule
