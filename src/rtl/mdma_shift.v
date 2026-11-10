// FAST=1 retains a fine/coarse boundary; FAST=2 computes all count bits
// together. FAST=0 also captures the operands and completed results.
module mdma_shift #(parameter FAST = 0) (
    input wire clk, reset, allow_start, operands_ready, output_full,
    input wire [63:0] value, count,
    output wire take, publish, progress,
    output wire [319:0] results
);
    generate
        if (FAST == 2) begin: single_stage
            wire [5:0] amount = count[5:0];
            wire [127:0] twice = {value, value};
            wire [127:0] rotate_left = twice << amount;
            wire [127:0] rotate_right = twice >> amount;
            assign results[63:0] = value << amount;
            assign results[127:64] = value >> amount;
            assign results[191:128] = $signed(value) >>> amount;
            assign results[255:192] = rotate_left[127:64];
            assign results[319:256] = rotate_right[63:0];
            assign take = allow_start && operands_ready && !output_full;
            assign publish = take;
            assign progress = take;
        end else begin: split_stages
            reg input_valid, fine_valid, result_valid;
            reg [63:0] saved_operand;
            reg [5:0] saved_amount;
            reg [319:0] saved_result;
            wire [63:0] operand = FAST ? value : saved_operand;
            wire [5:0] amount = FAST ? count[5:0] : saved_amount;
            reg [2:0] coarse_amount;
            reg [63:0] fine_lsl, fine_lsr, fine_asr, fine_rol, fine_ror;
            wire [2:0] fine = amount[2:0];
            wire [5:0] coarse = {coarse_amount, 3'b0};
            wire [127:0] operand_twice = {operand, operand};
            wire [127:0] left_fine = operand_twice << fine;
            wire [127:0] right_fine = operand_twice >> fine;
            wire [127:0] left_coarse = {fine_rol, fine_rol} << coarse;
            wire [127:0] right_coarse = {fine_ror, fine_ror} >> coarse;
            wire [63:0] coarse_asr = $signed(fine_asr) >>> coarse;
            wire [319:0] computed = {right_coarse[63:0], left_coarse[127:64], coarse_asr,
                                    fine_lsr >> coarse, fine_lsl << coarse};
            wire advance = !(FAST ? fine_valid : result_valid) || !output_full;

            assign take = allow_start && operands_ready && advance;
            assign publish = (FAST ? fine_valid : result_valid) && !output_full;
            assign progress = take || (!FAST && advance && (input_valid || fine_valid)) || publish;
            assign results = FAST ? computed : saved_result;

            always @(posedge clk) begin
                if (reset) begin
                    input_valid <= 0;
                    fine_valid <= 0;
                    result_valid <= 0;
                end else if (advance) begin
                    input_valid <= take;
                    fine_valid <= FAST ? take : input_valid;
                    result_valid <= fine_valid;
                    if (!FAST && take) begin
                        saved_operand <= value;
                        saved_amount <= count[5:0];
                    end
                    if (FAST ? take : input_valid) begin
                        fine_lsl <= operand << fine;
                        fine_lsr <= operand >> fine;
                        fine_asr <= $signed(operand) >>> fine;
                        fine_rol <= left_fine[127:64];
                        fine_ror <= right_fine[63:0];
                        coarse_amount <= amount[5:3];
                    end
                    if (!FAST && fine_valid)
                        saved_result <= computed;
                end
            end
        end
    endgenerate
endmodule
