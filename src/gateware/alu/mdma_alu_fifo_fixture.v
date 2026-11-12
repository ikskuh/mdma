// Test boundary for one ALU. Each operand queues independently; one
// output entry keeps all sibling data and their validity bits together.
module mdma_alu_fifo_fixture #(
    parameter integer SINKS = 1,
    parameter integer SOURCES = 1,
    parameter integer STORAGE = 1,
    parameter integer FIFO_BYPASS = 1
) (
    input wire clk,
    input wire [65*SINKS+SOURCES:0] drive,
    output wire [SINKS+65*SOURCES-1:0] observed,
    output wire [65*SINKS+SOURCES:0] alu_inputs,
    input wire [SINKS+65*SOURCES-1:0] alu_outputs
);
    wire reset = drive[0];
    assign alu_inputs[0] = reset;

    for (genvar lane = 0; lane < SINKS; lane = lane + 1) begin : operands
        localparam integer DATA = 1 + 65*lane;
        localparam integer VALID = DATA + 64;
        mdma_fifo #(.IMPLEMENTATION(STORAGE), .DEPTH(4), .WIDTH(64), .BYPASS(FIFO_BYPASS)) input_fifo (
            .clk(clk), .reset(reset),
            .i_in_data(drive[DATA +: 64]), .i_in_valid(drive[VALID]), .i_in_take(observed[lane]),
            .o_out_data(alu_inputs[DATA +: 64]), .o_out_valid(alu_inputs[VALID]),
            .o_out_take(alu_outputs[lane])
        );
    end

    wire [SOURCES-1:0] result_valid, retire;
    wire [65*SOURCES-1:0] head;
    wire group_valid, group_push;
    for (genvar lane = 0; lane < SOURCES; lane = lane + 1) begin : results
        localparam integer DATA = SINKS + 65*lane;
        localparam integer TAKE = 1 + 65*SINKS + lane;
        assign result_valid[lane] = alu_outputs[DATA+64];
        assign alu_inputs[TAKE] = group_push;
        assign observed[DATA +: 64] = head[65*lane +: 64];
        assign observed[DATA+64] = group_valid && head[65*lane+64];
        assign retire[lane] = drive[TAKE] && observed[DATA+64];
    end

    mdma_fifo #(.IMPLEMENTATION(STORAGE), .DEPTH(4), .WIDTH(65*SOURCES), .BYPASS(FIFO_BYPASS)) output_fifo (
        .clk(clk), .reset(reset),
        .i_in_data(alu_outputs[SINKS +: 65*SOURCES]), .i_in_valid(|result_valid), .i_in_take(group_push),
        .o_out_data(head), .o_out_valid(group_valid), .o_out_take(|retire)
    );
endmodule
