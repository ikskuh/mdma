// Register cuts separate groups of radix-2 restoring steps.
module mdma_div_pipeline #(
    parameter [63:0] CUTS = 64'hffff_ffff_ffff_ffff,
    parameter SIGN_INPUT = 0,
    parameter LIMB_BITS = 0
) (
    input wire clk, reset,
    input wire [63:0] dividend, divisor,
    input wire lhs_negative, rhs_negative, fault,
    input wire operands_valid,
    output wire operands_take,
    output wire [63:0] quo, rem,
    output wire fault_valid, normal_valid,
    input wire normal_take, fault_take
);
    function integer count_cuts;
        input [63:0] mask;
        begin
            count_cuts = 0;
            for (integer bit_index = 0; bit_index < 64; bit_index = bit_index + 1)
                count_cuts = count_cuts + mask[bit_index];
        end
    endfunction

    localparam STAGES = count_cuts(CUTS) + SIGN_INPUT;
    reg [STAGES-1:0] valid;
    wire [STAGES-1:0] advance;
    wire [63:0] dividend_at [0:64];
    wire [63:0] divisor_at [0:64];
    wire [63:0] quotient_at [0:64];
    wire [63:0] remainder_at [0:64];
    wire [2:0] flags_at [0:64];
    wire tail_fault = flags_at[64][0];
    wire consumer_take = tail_fault ? fault_take : normal_take;

    if (!CUTS[63]) begin : invalid_cuts
        initial $fatal(1, "The final divider step requires a register");
    end

    assign operands_take = !reset && operands_valid && advance[0];
    assign normal_valid = !reset && valid[STAGES-1] && !tail_fault;
    assign fault_valid = !reset && valid[STAGES-1] && tail_fault;
    assign quo = flags_at[64][2] ? -quotient_at[64] : quotient_at[64];
    assign rem = flags_at[64][1] ? -remainder_at[64] : remainder_at[64];

    // A bubble allows its upstream stages to advance. An empty tail is
    // already included in the reduction, so consumer take needs no valid gate.
    for (genvar stage = 0; stage < STAGES; stage = stage + 1) begin : handshake
        wire incoming;
        if (stage == 0) begin : input_valid
            assign incoming = operands_valid;
        end else begin : previous_valid
            assign incoming = valid[stage-1];
        end
        assign advance[stage] = consumer_take || !(&valid[STAGES-1:stage]);

        always @(posedge clk) begin
            if (reset)
                valid[stage] <= 1'b0;
            else if (advance[stage])
                valid[stage] <= incoming;
        end
    end

    wire [2:0] input_flags = {lhs_negative ^ rhs_negative, lhs_negative, fault};
    if (SIGN_INPUT) begin : capture_sign_input
        reg [130:0] saved;

        always @(posedge clk)
            if (advance[0])
                saved <= {dividend, divisor, input_flags};

        assign {dividend_at[0], divisor_at[0], flags_at[0]} = saved;
    end else begin : direct_input
        assign {dividend_at[0], divisor_at[0], flags_at[0]} = {dividend, divisor, input_flags};
    end

    assign quotient_at[0] = 64'b0;
    assign remainder_at[0] = 64'b0;

    for (genvar step = 1; step <= 64; step = step + 1) begin : divide_bit
        wire [step-1:0] trial;
        if (step == 1) begin : first_bit
            assign trial = dividend_at[0][63];
        end else begin : later_bits
            assign trial = {remainder_at[step-1][step-2:0], dividend_at[step-1][64-step]};
        end

        wire [step-1:0] low_divisor = divisor_at[step-1][step-1:0];
        wire [step:0] difference;
        if (LIMB_BITS == 0 || step <= LIMB_BITS) begin : subtract
            assign difference = {1'b0, trial} - {1'b0, low_divisor};
        end else begin : carry_select
            localparam LIMBS = (step + LIMB_BITS - 1) / LIMB_BITS;
            wire [LIMBS:0] borrow;
            assign borrow[0] = 1'b0;
            assign difference[step] = borrow[LIMBS];

            for (genvar limb = 0; limb < LIMBS; limb = limb + 1) begin : part
                localparam LO = limb * LIMB_BITS;
                localparam WIDTH = step - LO < LIMB_BITS ? step - LO : LIMB_BITS;
                wire [WIDTH-1:0] a = trial[LO +: WIDTH];
                wire [WIDTH-1:0] b = low_divisor[LO +: WIDTH];
                wire [WIDTH:0] direct = {1'b0, a} - {1'b0, b};
                wire [WIDTH-1:0] with_borrow = a + ~b;
                assign borrow[limb+1] = direct[WIDTH] || (a == b && borrow[limb]);
                assign difference[LO +: WIDTH] = borrow[limb] ? with_borrow : direct[WIDTH-1:0];
            end
        end

        wire divisor_fits;
        if (step == 64) begin : full_width
            assign divisor_fits = 1'b1;
        end else begin : partial_width
            assign divisor_fits = !(|divisor_at[step-1][63:step]);
        end

        wire bit_value = divisor_fits && !difference[step];
        wire [63:0] quotient = {quotient_at[step-1][62:0], bit_value};
        wire [63:0] remainder = {{(64-step){1'b0}}, bit_value ? difference[step-1:0] : trial};
        wire [258:0] state_out = {dividend_at[step-1], divisor_at[step-1],
                                  quotient, remainder, flags_at[step-1]};
        if (CUTS[step-1]) begin : cut
            localparam STAGE = count_cuts(CUTS << (64-step)) + SIGN_INPUT - 1;
            reg [258:0] saved;

            always @(posedge clk)
                if (advance[STAGE])
                    saved <= state_out;

            assign {dividend_at[step], divisor_at[step], quotient_at[step],
                    remainder_at[step], flags_at[step]} = saved;
        end else begin : direct
            assign {dividend_at[step], divisor_at[step], quotient_at[step],
                    remainder_at[step], flags_at[step]} = state_out;
        end
    end
endmodule
