module mdma_bitcnt #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_in_data,
    input wire i_in_valid,
    output wire i_in_take,
    output wire [63:0] o_pop_data,
    output wire o_pop_valid,
    input wire o_pop_take,
    output wire [63:0] o_clz_data,
    output wire o_clz_valid,
    input wire o_clz_take,
    output wire [63:0] o_ctz_data,
    output wire o_ctz_valid,
    input wire o_ctz_take
);
    // A balanced sum tree and a binary search for the first set bit.
    wire [6:0] sum [1:127];
    wire [63:0] reversed;

    for (genvar bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin : bits
        assign sum[64+bit_index] = {6'b0, i_in_data[bit_index]};
        assign reversed[bit_index] = i_in_data[63-bit_index];
    end
    for (genvar node = 1; node < 64; node = node + 1) begin : popcount
        assign sum[node] = sum[2*node] + sum[2*node+1];
    end

    function [6:0] leading_zeros;
        input [63:0] value;
        reg [63:0] remaining;
        integer half_width;
        begin
            leading_zeros = 0;
            remaining = value;
            for (half_width = 32; half_width > 0; half_width = half_width / 2) begin
                if (!(|(remaining >> (64-half_width)))) begin
                    leading_zeros = leading_zeros + half_width[6:0];
                    remaining = remaining << half_width;
                end
            end
            if (value == 0)
                leading_zeros = 7'd64;
        end
    endfunction

    wire [63:0] result_pop = {57'b0, sum[1]};
    wire [63:0] result_clz = {57'b0, leading_zeros(i_in_data)};
    wire [63:0] result_ctz = {57'b0, leading_zeros(reversed)};

    wire accept;
    assign i_in_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(3)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_in_valid),
        .operands_take(accept),
        .result_data({result_pop, result_clz, result_ctz}),
        .result_mask(3'b111),
        .take({o_pop_take, o_clz_take, o_ctz_take}),
        .data({o_pop_data, o_clz_data, o_ctz_data}),
        .valid({o_pop_valid, o_clz_valid, o_ctz_valid})
    );
endmodule
