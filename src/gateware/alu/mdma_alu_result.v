// All lanes belong to a single transaction. The mask selects normal results
// or the fault lane, and a take on any selected lane retires the transaction.
module mdma_alu_result #(
    parameter REGISTERED = 1,
    parameter LANES = 1
) (
    input wire clk,
    input wire reset,
    input wire operands_valid,
    output wire operands_take,
    input wire [64*LANES-1:0] result_data,
    input wire [LANES-1:0] result_mask,
    input wire [LANES-1:0] take,
    output wire [64*LANES-1:0] data,
    output wire [LANES-1:0] valid
);
    wire retire = |(valid & take);

    generate
        if (REGISTERED) begin : registered
            reg occupied;
            reg [64*LANES-1:0] saved_data;
            reg [LANES-1:0] saved_mask;

            assign operands_take = !reset && operands_valid && (!occupied || retire);
            assign data = saved_data;
            assign valid = !reset && occupied ? saved_mask : {LANES{1'b0}};

            always @(posedge clk) begin
                if (reset)
                    occupied <= 1'b0;
                else if (operands_take)
                    occupied <= 1'b1;
                else if (retire)
                    occupied <= 1'b0;

                if (operands_take) begin
                    saved_data <= result_data;
                    saved_mask <= result_mask;
                end
            end
        end else begin : passthrough
            assign operands_take = retire;
            assign data = result_data;
            assign valid = !reset && operands_valid ? result_mask : {LANES{1'b0}};
        end
    endgenerate
endmodule
