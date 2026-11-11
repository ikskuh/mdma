module mdma_mask #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_n_data,
    input wire i_n_valid,
    output wire i_n_take,
    output wire [63:0] o_mask_data,
    output wire o_mask_valid,
    input wire o_mask_take,
    output wire [63:0] o_bit_data,
    output wire o_bit_valid,
    input wire o_bit_take
);
    wire in_range = i_n_data[63:6] == 0;
    wire [63:0] bit_at_count = 64'b1 << i_n_data[5:0];
    wire [63:0] result_mask = in_range ? bit_at_count - 64'b1 : {64{1'b1}};
    wire [63:0] result_bit = in_range ? bit_at_count : 64'b0;

    wire accept;
    assign i_n_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(2)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_n_valid),
        .operands_take(accept),
        .result_data({result_mask, result_bit}),
        .result_mask(2'b11),
        .take({o_mask_take, o_bit_take}),
        .data({o_mask_data, o_bit_data}),
        .valid({o_mask_valid, o_bit_valid})
    );
endmodule
