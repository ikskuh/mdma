module mdma_logic #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_lhs_data,
    input wire i_lhs_valid,
    output wire i_lhs_take,
    input wire [63:0] i_rhs_data,
    input wire i_rhs_valid,
    output wire i_rhs_take,
    output wire [63:0] o_and_data,
    output wire o_and_valid,
    input wire o_and_take,
    output wire [63:0] o_or_data,
    output wire o_or_valid,
    input wire o_or_take,
    output wire [63:0] o_xor_data,
    output wire o_xor_valid,
    input wire o_xor_take
);
    wire [63:0] result_and = i_lhs_data & i_rhs_data;
    wire [63:0] result_or = i_lhs_data | i_rhs_data;
    wire [63:0] result_xor = i_lhs_data ^ i_rhs_data;

    wire accept;
    assign i_lhs_take = accept;
    assign i_rhs_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(3)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_lhs_valid && i_rhs_valid),
        .operands_take(accept),
        .result_data({result_and, result_or, result_xor}),
        .result_mask(3'b111),
        .take({o_and_take, o_or_take, o_xor_take}),
        .data({o_and_data, o_or_data, o_xor_data}),
        .valid({o_and_valid, o_or_valid, o_xor_valid})
    );
endmodule
