module mdma_sel #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_cond_data,
    input wire i_cond_valid,
    output wire i_cond_take,
    input wire [63:0] i_true_data,
    input wire i_true_valid,
    output wire i_true_take,
    input wire [63:0] i_false_data,
    input wire i_false_valid,
    output wire i_false_take,
    output wire [63:0] o_out_data,
    output wire o_out_valid,
    input wire o_out_take
);
    wire [63:0] result_out = (|i_cond_data) ? i_true_data : i_false_data;

    wire accept;
    assign i_cond_take = accept;
    assign i_true_take = accept;
    assign i_false_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(1)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_cond_valid && i_true_valid && i_false_valid),
        .operands_take(accept),
        .result_data(result_out),
        .result_mask(1'b1),
        .take(o_out_take),
        .data(o_out_data),
        .valid(o_out_valid)
    );
endmodule
