// Target n occupies o_data[n*WIDTH +: WIDTH] and o_valid[n].
module mdma_sink_selector #(
    parameter integer WIDTH = 64,
    parameter integer SELECT_BITS = 6,
    parameter integer IMPLEMENTATION = 0
) (
    input wire [WIDTH-1:0] i_data,
    input wire [SELECT_BITS-1:0] i_address,
    output wire [(2**SELECT_BITS)*WIDTH-1:0] o_data,
    output wire [(2**SELECT_BITS)-1:0] o_valid
);
    localparam integer TARGETS = 2**SELECT_BITS;

    generate
        if (WIDTH < 1 || SELECT_BITS < 1) begin : invalid_shape
            initial $fatal(1, "mdma_sink_selector requires positive WIDTH and SELECT_BITS");
        end

        if (IMPLEMENTATION == 0) begin : shared_bus
            wire [SELECT_BITS+WIDTH-1:0] bus_lanes = {i_address, i_data};

            for (genvar target = 0; target < TARGETS; target = target + 1) begin : receiver
                localparam [SELECT_BITS-1:0] ADDRESS = target;
                assign o_valid[target] = bus_lanes[WIDTH +: SELECT_BITS] == ADDRESS;
                assign o_data[target*WIDTH +: WIDTH] = bus_lanes[0 +: WIDTH];
            end
        end else if (IMPLEMENTATION == 1 || IMPLEMENTATION == 2) begin : central_select
            // Each mux directs the preceding valid lanes into one half of
            // the next stage, starting with a single asserted lane.
            wire [TARGETS-1:0] lanes [0:SELECT_BITS];
            assign lanes[0] = 1;
            for (genvar bit_index = 0; bit_index < SELECT_BITS; bit_index = bit_index + 1) begin : step
                localparam integer ACTIVE = 2**bit_index;
                wire [ACTIVE-1:0] prior = lanes[bit_index][0 +: ACTIVE];
                wire [2*ACTIVE-1:0] next_lanes = i_address[bit_index] ?
                    {prior, {ACTIVE{1'b0}}} : {{ACTIVE{1'b0}}, prior};
                assign lanes[bit_index+1] = {{(TARGETS-2*ACTIVE){1'b0}}, next_lanes};
            end

            assign o_valid = lanes[SELECT_BITS];
            for (genvar target = 0; target < TARGETS; target = target + 1) begin : receiver
                if (IMPLEMENTATION == 1) begin : data_mux
                    assign o_data[target*WIDTH +: WIDTH] =
                        o_valid[target] ? i_data : {WIDTH{1'b0}};
                end else begin : select_mux
                    assign o_data[target*WIDTH +: WIDTH] = i_data;
                end
            end
        end else begin : invalid_implementation
            initial $fatal(1, "Unknown sink selector IMPLEMENTATION");
        end
    endgenerate
endmodule
