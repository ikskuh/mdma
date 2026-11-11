module mdma_swizzle8 #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_value_data,
    input wire i_value_valid,
    output wire i_value_take,
    input wire [63:0] i_pattern_data,
    input wire i_pattern_valid,
    output wire i_pattern_take,
    output wire [63:0] o_value_data,
    output wire o_value_valid,
    input wire o_value_take
);
    wire [63:0] result_value;
    for (genvar lane = 0; lane < 8; lane = lane + 1) begin : select_byte
        wire [5:0] shift = {i_pattern_data[3*lane +: 3], 3'b0};
        assign result_value[8*lane +: 8] = i_value_data[shift +: 8];
    end

    wire accept;
    assign i_value_take = accept;
    assign i_pattern_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(1)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_value_valid && i_pattern_valid),
        .operands_take(accept),
        .result_data(result_value),
        .result_mask(1'b1),
        .take(o_value_take),
        .data(o_value_data),
        .valid(o_value_valid)
    );
endmodule
