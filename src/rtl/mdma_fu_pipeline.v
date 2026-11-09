// Common flow control for fixed-function, single-compute-cycle units.
module mdma_fu_pipeline #(parameter INPUTS = 2, parameter OUTPUTS = 1) (
    input wire clk, reset, allow_start, operands_ready, output_full,
    input wire [INPUTS*64-1:0] operands_in,
    output reg [INPUTS*64-1:0] operands,
    input wire [OUTPUTS*64-1:0] computed,
    output wire take, publish, progress,
    output reg [OUTPUTS*64-1:0] results
);
    reg operand_valid, result_valid;
    wire advance = !result_valid || !output_full;
    assign take = allow_start && operands_ready && advance;
    assign publish = result_valid && !output_full;
    assign progress = take || (operand_valid && advance) || publish;

    always @(posedge clk) begin
        if (reset) begin
            operand_valid <= 0;
            result_valid <= 0;
        end else if (advance) begin
            operand_valid <= take;
            result_valid <= operand_valid;
            if (take)
                operands <= operands_in;
            if (operand_valid)
                results <= computed;
        end
    end
endmodule
