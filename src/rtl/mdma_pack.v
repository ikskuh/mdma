module mdma_pack(input wire [63:0] address, kind, value, output wire [191:0] results);
    reg [63:0] type_mask;
    reg [7:0] type_lanes;
    always @* begin
        case (kind[2:1])
            0: begin type_mask = 64'hff; type_lanes = 8'h01; end
            1: begin type_mask = 64'hffff; type_lanes = 8'h03; end
            2: begin type_mask = 64'hffffffff; type_lanes = 8'h0f; end
            default: begin type_mask = 64'hffffffffffffffff; type_lanes = 8'hff; end
        endcase
    end
    assign results[63:0] = (value & type_mask) << {address[2:0], 3'b0};
    assign results[127:64] = {56'b0, ~(type_lanes << address[2:0])};
    assign results[191:128] = address;
endmodule
