// Bus n occupies i_source_data[n*64 +: 64] and i_source_ready[n].
// Sink n uses i_source_id[n*3 +: 3] and o_sink_data[n*64 +: 64].
// The caller maps at most five sinks and retires each mapping after capture.
module mdma_fifo_write_mux (
    input wire [319:0] i_source_data,
    input wire [4:0] i_source_ready,
    input wire [191:0] i_source_id,
    input wire [63:0] i_sink_done,
    output wire [4095:0] o_sink_data,
    output wire [63:0] o_sink_ready,
    output wire [63:0] o_sink_done
);
    wire [64:0] source_bus [0:4];
    for (genvar bus = 0; bus < 5; bus = bus + 1) begin : source
        assign source_bus[bus] = {i_source_ready[bus], i_source_data[bus*64 +: 64]};
    end

    for (genvar sink = 0; sink < 64; sink = sink + 1) begin : target
        // Bit 5 marks a disabled sink. IDs 6 and 7 are don't-cares.
        reg [5:0] select_bus;
        always @* begin
            case (i_source_id[sink*3 +: 3])
                3'd0: select_bus = 6'b000001;
                3'd1: select_bus = 6'b000010;
                3'd2: select_bus = 6'b000100;
                3'd3: select_bus = 6'b001000;
                3'd4: select_bus = 6'b010000;
                3'd5: select_bus = 6'b100000;
                default: select_bus = 6'bxxxxxx;
            endcase
        end

        assign {o_sink_ready[sink], o_sink_data[sink*64 +: 64]} =
            ({65{select_bus[0]}} & source_bus[0]) |
            ({65{select_bus[1]}} & source_bus[1]) |
            ({65{select_bus[2]}} & source_bus[2]) |
            ({65{select_bus[3]}} & source_bus[3]) |
            ({65{select_bus[4]}} & source_bus[4]);
        assign o_sink_done[sink] = select_bus[5] | i_sink_done[sink];
    end
endmodule
