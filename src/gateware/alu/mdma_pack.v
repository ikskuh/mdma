module mdma_pack #(
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
    input wire [63:0] i_value_data,
    input wire i_value_valid,
    output wire i_value_take,
    output wire [63:0] o_addr_data,
    output wire o_addr_valid,
    input wire o_addr_take,
    output wire [63:0] o_chunk_data,
    output wire o_chunk_valid,
    input wire o_chunk_take,
    output wire [63:0] o_mask_data,
    output wire o_mask_valid,
    input wire o_mask_take,
    output wire [63:0] o_fault_data,
    output wire o_fault_valid,
    input wire o_fault_take
);
    wire [2:0] lane = i_addr_data[2:0];
    wire [5:0] shift = {lane, 3'b0};
    wire [7:0] lane_mask;
    wire invalid_type, misaligned;
    wire [63:0] value_mask;

    mdma_typed_lanes layout (
        .lane(lane), .type_code(i_type_data), .invalid_type(invalid_type),
        .misaligned(misaligned), .lane_mask(lane_mask), .value_mask(value_mask)
    );

    wire [63:0] result_addr = i_addr_data;
    wire [63:0] result_chunk = (i_value_data & value_mask) << shift;
    wire [63:0] result_mask = {56'b0, ~(lane_mask << lane)};
    wire [63:0] result_fault = invalid_type ? 64'd1 : misaligned ? 64'd2 : 64'd0;
    wire failed = |result_fault;

    wire accept;
    assign i_addr_take = accept;
    assign i_type_take = accept;
    assign i_value_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(4)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_addr_valid && i_type_valid && i_value_valid),
        .operands_take(accept),
        .result_data({result_addr, result_chunk, result_mask, result_fault}),
        .result_mask({{3{!failed}}, failed}),
        .take({o_addr_take, o_chunk_take, o_mask_take, o_fault_take}),
        .data({o_addr_data, o_chunk_data, o_mask_data, o_fault_data}),
        .valid({o_addr_valid, o_chunk_valid, o_mask_valid, o_fault_valid})
    );
endmodule
