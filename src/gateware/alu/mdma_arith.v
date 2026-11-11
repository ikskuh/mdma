module mdma_arith #(
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
    output wire [63:0] o_add_data,
    output wire o_add_valid,
    input wire o_add_take,
    output wire [63:0] o_sub_data,
    output wire o_sub_valid,
    input wire o_sub_take
);
    wire [63:0] result_add = i_lhs_data + i_rhs_data;
    wire [63:0] result_sub = i_lhs_data - i_rhs_data;

    wire accept;
    assign i_lhs_take = accept;
    assign i_rhs_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(2)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_lhs_valid && i_rhs_valid),
        .operands_take(accept),
        .result_data({result_add, result_sub}),
        .result_mask(2'b11),
        .take({o_add_take, o_sub_take}),
        .data({o_add_data, o_sub_data}),
        .valid({o_add_valid, o_sub_valid})
    );
endmodule
