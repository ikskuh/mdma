module mdma_shift #(
    parameter REGISTERED = 1
) (
    input wire clk,
    input wire reset,
    input wire [63:0] i_val_data,
    input wire i_val_valid,
    output wire i_val_take,
    input wire [63:0] i_cnt_data,
    input wire i_cnt_valid,
    output wire i_cnt_take,
    output wire [63:0] o_lsl_data,
    output wire o_lsl_valid,
    input wire o_lsl_take,
    output wire [63:0] o_lsr_data,
    output wire o_lsr_valid,
    input wire o_lsr_take,
    output wire [63:0] o_asr_data,
    output wire o_asr_valid,
    input wire o_asr_take,
    output wire [63:0] o_rol_data,
    output wire o_rol_valid,
    input wire o_rol_take,
    output wire [63:0] o_ror_data,
    output wire o_ror_valid,
    input wire o_ror_take
);
    wire [5:0] count = i_cnt_data[5:0];
    wire [5:0] inverse_count = -count;
    wire [63:0] result_lsl = i_val_data << count;
    wire [63:0] result_lsr = i_val_data >> count;
    wire [63:0] result_asr = $signed(i_val_data) >>> count;
    wire [63:0] result_rol = result_lsl | (i_val_data >> inverse_count);
    wire [63:0] result_ror = result_lsr | (i_val_data << inverse_count);

    wire accept;
    assign i_val_take = accept;
    assign i_cnt_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(5)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_val_valid && i_cnt_valid),
        .operands_take(accept),
        .result_data({result_lsl, result_lsr, result_asr, result_rol, result_ror}),
        .result_mask(5'b11111),
        .take({o_lsl_take, o_lsr_take, o_asr_take, o_rol_take, o_ror_take}),
        .data({o_lsl_data, o_lsr_data, o_asr_data, o_rol_data, o_ror_data}),
        .valid({o_lsl_valid, o_lsr_valid, o_asr_valid, o_rol_valid, o_ror_valid})
    );
endmodule
