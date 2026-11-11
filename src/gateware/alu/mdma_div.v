module mdma_div #(
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
    output wire [63:0] o_quo_data,
    output wire o_quo_valid,
    input wire o_quo_take,
    output wire [63:0] o_rem_data,
    output wire o_rem_valid,
    input wire o_rem_take,
    output wire [63:0] o_fault_data,
    output wire o_fault_valid,
    input wire o_fault_take
);
    wire lhs_negative = SIGNED_OP && i_lhs_data[63];
    wire rhs_negative = SIGNED_OP && i_rhs_data[63];
    wire [63:0] dividend = lhs_negative ? -i_lhs_data : i_lhs_data;
    wire [63:0] divisor = rhs_negative ? -i_rhs_data : i_rhs_data;
    wire [63:0] quotient;
    wire [63:0] remainder [0:64];

    assign remainder[0] = 64'b0;
    // One restoring step per dividend bit. Each partial remainder can only
    // contain the dividend bits processed so far.
    for (genvar step = 1; step <= 64; step = step + 1) begin : divide_bit
        wire [step-1:0] trial;
        if (step == 1) begin : first_bit
            assign trial = dividend[63];
        end else begin : later_bits
            assign trial = {remainder[step-1][step-2:0], dividend[64-step]};
        end

        wire [step:0] difference = {1'b0, trial} - {1'b0, divisor[step-1:0]};
        wire divisor_fits;
        if (step == 64) begin : full_width
            assign divisor_fits = 1'b1;
        end else begin : partial_width
            assign divisor_fits = !(|divisor[63:step]);
        end

        assign quotient[64-step] = divisor_fits && !difference[step];
        assign remainder[step] = {{(64-step){1'b0}},
                                  quotient[64-step] ? difference[step-1:0] : trial};
    end

    wire [63:0] result_quo = lhs_negative ^ rhs_negative ? -quotient : quotient;
    wire [63:0] result_rem = lhs_negative ? -remainder[64] : remainder[64];
    wire [63:0] result_fault = i_rhs_data == 0 ? 64'd3 : 64'd0;
    wire failed = |result_fault;

    wire accept;
    assign i_lhs_take = accept;
    assign i_rhs_take = accept;

    mdma_alu_result #(.REGISTERED(REGISTERED), .LANES(3)) result (
        .clk(clk), .reset(reset),
        .operands_valid(i_lhs_valid && i_rhs_valid),
        .operands_take(accept),
        .result_data({result_quo, result_rem, result_fault}),
        .result_mask({{2{!failed}}, failed}),
        .take({o_quo_take, o_rem_take, o_fault_take}),
        .data({o_quo_data, o_rem_data, o_fault_data}),
        .valid({o_quo_valid, o_rem_valid, o_fault_valid})
    );
endmodule
