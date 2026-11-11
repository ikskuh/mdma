module mdma_unpack #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_addr_data,
    input wire i_addr_valid,
    output wire i_addr_take,
    input wire [63:0] i_type_data,
    input wire i_type_valid,
    output wire i_type_take,
    input wire [63:0] i_chunk_data,
    input wire i_chunk_valid,
    output wire i_chunk_take,
    output wire [63:0] o_value_data,
    output wire o_value_valid,
    input wire o_value_take,
    output wire [63:0] o_fault_data,
    output wire o_fault_valid,
    input wire o_fault_take
);
    wire [2:0] lane = i_addr_data[2:0];
    wire [5:0] shift = {lane, 3'b0};
    wire invalid_type, misaligned;
    wire [63:0] value_mask;

    mdma_typed_lanes layout (
        .lane(lane), .type_code(i_type_data), .invalid_type(invalid_type),
        .misaligned(misaligned), .lane_mask(), .value_mask(value_mask)
    );

    wire [63:0] shifted = i_chunk_data >> shift;
    wire [63:0] truncated = shifted & value_mask;
    wire [5:0] sign_index = {i_type_data[2] ? (i_type_data[1] ? 3'd7 : 3'd3) :
                                             (i_type_data[1] ? 3'd1 : 3'd0), 3'b111};
    wire sign_extend = i_type_data[0] && shifted[sign_index];
    wire [63:0] result_value = truncated | ({64{sign_extend}} & ~value_mask);
    wire [63:0] result_fault = invalid_type ? 64'd1 : misaligned ? 64'd2 : 64'd0;
    wire failed = |result_fault;

    wire accept;
    assign i_addr_take = accept;
    assign i_type_take = accept;
    assign i_chunk_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(2)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_addr_valid && i_type_valid && i_chunk_valid),
        .operands_take(accept),
        .result_data({result_value, result_fault}),
        .result_mask({!failed, failed}),
        .take({o_value_take, o_fault_take}),
        .data({o_value_data, o_fault_data}),
        .valid({o_value_valid, o_fault_valid})
    );
endmodule
