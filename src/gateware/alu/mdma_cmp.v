module mdma_cmp #(
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
    output wire [63:0] o_eq_data,
    output wire o_eq_valid,
    input wire o_eq_take,
    output wire [63:0] o_ne_data,
    output wire o_ne_valid,
    input wire o_ne_take,
    output wire [63:0] o_lt_data,
    output wire o_lt_valid,
    input wire o_lt_take,
    output wire [63:0] o_lts_data,
    output wire o_lts_valid,
    input wire o_lts_take,
    output wire [63:0] o_lte_data,
    output wire o_lte_valid,
    input wire o_lte_take,
    output wire [63:0] o_ltes_data,
    output wire o_ltes_valid,
    input wire o_ltes_take
);
    wire equal = i_lhs_data == i_rhs_data;
    wire less_unsigned = i_lhs_data < i_rhs_data;
    wire signs_differ = i_lhs_data[63] ^ i_rhs_data[63];
    wire less_signed = signs_differ ? i_lhs_data[63] : less_unsigned;
    wire [63:0] result_eq = {63'b0, equal};
    wire [63:0] result_ne = {63'b0, !equal};
    wire [63:0] result_lt = {63'b0, less_unsigned};
    wire [63:0] result_lts = {63'b0, less_signed};
    wire [63:0] result_lte = {63'b0, less_unsigned || equal};
    wire [63:0] result_ltes = {63'b0, less_signed || equal};

    wire accept;
    assign i_lhs_take = accept;
    assign i_rhs_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(6)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_lhs_valid && i_rhs_valid),
        .operands_take(accept),
        .result_data({result_eq, result_ne, result_lt, result_lts, result_lte, result_ltes}),
        .result_mask(6'b111111),
        .take({o_eq_take, o_ne_take, o_lt_take, o_lts_take, o_lte_take, o_ltes_take}),
        .data({o_eq_data, o_ne_data, o_lt_data, o_lts_data, o_lte_data, o_ltes_data}),
        .valid({o_eq_valid, o_ne_valid, o_lt_valid, o_lts_valid, o_lte_valid, o_ltes_valid})
    );
endmodule
