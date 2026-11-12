// Fixture endpoints keep the full 64-way selectors observable at the boundary.
module mdma_selector_chain_fixture #(
    parameter integer CHAIN = 0,
    parameter integer SINK_MODE = 0,
    parameter integer SOURCE_MODE = 0,
    parameter integer REGISTERED = 1,
    parameter integer BYPASS = 1,
    parameter integer ACTIVE_SOURCES = CHAIN == 1 ? 1 : 3
) (
    input wire clk, reset,
    input wire [63:0] i_data,
    input wire i_valid,
    input wire [5:0] i_sink_address, i_source_address,
    input wire i_take,
    input wire [62:0] i_other_sink_ready,
    input wire [64*(64-ACTIVE_SOURCES)-1:0] i_other_source_data,
    input wire [63-ACTIVE_SOURCES:0] i_other_source_valid,
    output wire [4095:0] o_sink_data,
    output wire [63:0] o_sink_valid,
    output wire o_input_take,
    output wire [63:0] o_data,
    output wire o_valid,
    output wire [63:0] o_source_take
);
    wire [63:0] sink_selected;
    wire active_take;
    wire [64*ACTIVE_SOURCES-1:0] active_data;
    wire [ACTIVE_SOURCES-1:0] active_valid;
    wire [63:0] source_valid = {i_other_source_valid, active_valid} & {64{!reset}};

    mdma_sink_selector #(.IMPLEMENTATION(SINK_MODE)) sink_selector (
        .i_data(i_data), .i_address(i_sink_address), .o_data(o_sink_data), .o_valid(sink_selected)
    );

    assign o_sink_valid = sink_selected & {64{i_valid && !reset}};
    assign o_input_take = |(o_sink_valid & {i_other_sink_ready, active_take});

    mdma_source_selector #(.IMPLEMENTATION(SOURCE_MODE)) source_selector (
        .i_data({i_other_source_data, active_data}), .i_valid(source_valid),
        .i_address(i_source_address), .o_data(o_data), .o_valid(o_valid)
    );

    for (genvar lane = 0; lane < 64; lane = lane + 1) begin : source_handshake
        localparam [5:0] ADDRESS = lane;
        assign o_source_take[lane] = i_take && source_valid[lane] && i_source_address == ADDRESS;
    end

    generate
        if (CHAIN == 1) begin : fifo_path
            mdma_fifo #(.IMPLEMENTATION(1), .DEPTH(4), .BYPASS(BYPASS)) queue (
                .clk(clk), .reset(reset),
                .i_in_data(o_sink_data[63:0]), .i_in_valid(o_sink_valid[0]), .i_in_take(active_take),
                .o_out_data(active_data), .o_out_valid(active_valid), .o_out_take(o_source_take[0])
            );
        end else begin : uop_path
            wire [68:0] drive = {o_source_take[2:0], o_sink_valid[0], o_sink_data[63:0], reset};
            wire [195:0] observed;
            wire [68:0] alu_inputs;
            wire [195:0] alu_outputs;

            if (CHAIN == 2) begin : buffered
                mdma_alu_fifo_fixture #(.SINKS(1), .SOURCES(3), .FIFO_BYPASS(BYPASS)) queues (
                    .clk(clk), .drive(drive), .observed(observed),
                    .alu_inputs(alu_inputs), .alu_outputs(alu_outputs)
                );
            end else begin : direct
                assign alu_inputs = drive;
                assign observed = alu_outputs;
            end

            mdma_uop #(.REGISTERED(REGISTERED)) uop (
                .clk(clk), .reset(reset),
                .i_in_data(alu_inputs[1 +: 64]), .i_in_valid(alu_inputs[65]), .i_in_take(alu_outputs[0]),
                .o_neg_data(alu_outputs[1 +: 64]), .o_neg_valid(alu_outputs[65]), .o_neg_take(alu_inputs[66]),
                .o_not_data(alu_outputs[66 +: 64]), .o_not_valid(alu_outputs[130]), .o_not_take(alu_inputs[67]),
                .o_bsw_data(alu_outputs[131 +: 64]), .o_bsw_valid(alu_outputs[195]), .o_bsw_take(alu_inputs[68])
            );

            assign active_take = observed[0];
            assign active_data = {observed[131 +: 64], observed[66 +: 64], observed[1 +: 64]};
            assign active_valid = {observed[195], observed[130], observed[65]};
        end
    endgenerate
endmodule
