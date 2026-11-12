// Source n occupies i_data[n*WIDTH +: WIDTH] and i_valid[n].
module mdma_source_selector #(
    parameter integer WIDTH = 64,
    parameter integer SELECT_BITS = 6,
    parameter integer IMPLEMENTATION = 0
) (
    input wire [(2**SELECT_BITS)*WIDTH-1:0] i_data,
    input wire [(2**SELECT_BITS)-1:0] i_valid,
    input wire [SELECT_BITS-1:0] i_address,
    output wire [WIDTH-1:0] o_data,
    output wire o_valid
);
    localparam integer SOURCES = 2**SELECT_BITS;
    localparam integer LANES = WIDTH + 1;
    wire [LANES-1:0] source_word [0:SOURCES-1];

    for (genvar source = 0; source < SOURCES; source = source + 1) begin : input_word
        assign source_word[source] = {i_valid[source], i_data[source*WIDTH +: WIDTH]};
    end

    generate
        if (WIDTH < 1 || SELECT_BITS < 1) begin : invalid_shape
            initial $fatal(1, "mdma_source_selector requires positive WIDTH and SELECT_BITS");
        end

        if (IMPLEMENTATION == 0) begin : classic_mux
            // Complete binary tree. The lowest address bit selects first.
            wire [LANES-1:0] nodes [1:2*SOURCES-1];
            for (genvar source = 0; source < SOURCES; source = source + 1) begin : leaf
                assign nodes[SOURCES+source] = source_word[source];
            end
            for (genvar level = 0; level < SELECT_BITS; level = level + 1) begin : stage
                localparam integer COUNT = SOURCES >> (level+1);
                for (genvar node = COUNT; node < 2*COUNT; node = node + 1) begin : mux
                    assign nodes[node] = i_address[level] ? nodes[2*node+1] : nodes[2*node];
                end
            end
            assign {o_valid, o_data} = nodes[1];
        end else if (IMPLEMENTATION == 1 || IMPLEMENTATION == 2) begin : wired_or
            wire [SOURCES-1:0] enable;
            if (IMPLEMENTATION == 1) begin : muxed_enables
                wire [SOURCES-1:0] lanes [0:SELECT_BITS];
                assign lanes[0] = 1;
                for (genvar bit_index = 0; bit_index < SELECT_BITS; bit_index = bit_index + 1) begin : step
                    localparam integer ACTIVE = 2**bit_index;
                    wire [ACTIVE-1:0] prior = lanes[bit_index][0 +: ACTIVE];
                    wire [2*ACTIVE-1:0] next_lanes = i_address[bit_index] ?
                        {prior, {ACTIVE{1'b0}}} : {{ACTIVE{1'b0}}, prior};
                    assign lanes[bit_index+1] = {{(SOURCES-2*ACTIVE){1'b0}}, next_lanes};
                end
                assign enable = lanes[SELECT_BITS];
            end else begin : address_lanes
                wire [SELECT_BITS-1:0] address = i_address;
                for (genvar source = 0; source < SOURCES; source = source + 1) begin : match
                    localparam [SELECT_BITS-1:0] SOURCE_ADDRESS = source;
                    assign enable[source] = address == SOURCE_ADDRESS;
                end
            end

            wire [LANES-1:0] bus_word;
            for (genvar lane = 0; lane < LANES; lane = lane + 1) begin : reduce_lane
                wire [SOURCES-1:0] contributions;
                for (genvar source = 0; source < SOURCES; source = source + 1) begin : driver
                    assign contributions[source] = enable[source] & source_word[source][lane];
                end
                assign bus_word[lane] = |contributions;
            end
            assign {o_valid, o_data} = bus_word;
        end else begin : invalid_implementation
            initial $fatal(1, "Unknown source selector IMPLEMENTATION");
        end
    endgenerate
endmodule
