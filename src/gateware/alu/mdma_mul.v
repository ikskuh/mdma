module mdma_mul #(
    parameter REGISTERED = 1,
    parameter SIGNED_OP = 0
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_lhs_data,
    input wire i_lhs_valid,
    output wire i_lhs_take,
    input wire [63:0] i_rhs_data,
    input wire i_rhs_valid,
    output wire i_rhs_take,
    output wire [63:0] o_lo_data,
    output wire o_lo_valid,
    input wire o_lo_take,
    output wire [63:0] o_hi_data,
    output wire o_hi_valid,
    input wire o_hi_take
);
    wire [127:0] product;
    generate
        if (SIGNED_OP) begin : signed_product
            assign product = $signed(i_lhs_data) * $signed(i_rhs_data);
        end else begin : unsigned_product
            assign product = i_lhs_data * i_rhs_data;
        end
    endgenerate

    wire [63:0] result_lo = product[63:0];
    wire [63:0] result_hi = product[127:64];

    wire accept;
    assign i_lhs_take = accept;
    assign i_rhs_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(2)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_lhs_valid && i_rhs_valid),
        .operands_take(accept),
        .result_data({result_lo, result_hi}),
        .result_mask(2'b11),
        .take({o_lo_take, o_hi_take}),
        .data({o_lo_data, o_hi_data}),
        .valid({o_lo_valid, o_hi_valid})
    );
endmodule
