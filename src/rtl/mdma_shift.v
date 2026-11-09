// Split each barrel operation at the three low count bits. Both stages
// handle one operand pair per clock, with shared backpressure.
module mdma_shift (
    input wire clk, reset, allow_start, operands_ready, output_full,
    input wire [63:0] value, count,
    output wire take, publish, progress,
    output reg [319:0] results
);
    reg input_valid, fine_valid, result_valid;
    reg [63:0] operand;
    reg [5:0] amount;
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
    wire advance = !result_valid || !output_full;

    assign take = allow_start && operands_ready && advance;
    assign publish = result_valid && !output_full;
    assign progress = take || (advance && (input_valid || fine_valid)) || publish;

    always @(posedge clk) begin
        if (reset) begin
            input_valid <= 0;
            fine_valid <= 0;
            result_valid <= 0;
        end else if (advance) begin
            input_valid <= take;
            fine_valid <= input_valid;
            result_valid <= fine_valid;
            if (take) begin
                operand <= value;
                amount <= count[5:0];
            end
            if (input_valid) begin
                fine_lsl <= operand << fine;
                fine_lsr <= operand >> fine;
                fine_asr <= $signed(operand) >>> fine;
                fine_rol <= left_fine[127:64];
                fine_ror <= right_fine[63:0];
                coarse_amount <= amount[5:3];
            end
            if (fine_valid)
                results <= {right_coarse[63:0], left_coarse[127:64], coarse_asr,
                            fine_lsr >> coarse, fine_lsl << coarse};
        end
    end
endmodule
