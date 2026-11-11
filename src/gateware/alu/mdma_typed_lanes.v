// PACK and UNPACK share the width, alignment, and mask rules.
module mdma_typed_lanes (
    input wire [2:0] lane,
    input wire [63:0] type_code,
    output wire invalid_type,
    output wire misaligned,
    output reg [7:0] lane_mask,
    output wire [63:0] value_mask
);
    wire [3:0] width_bytes = 4'b0001 << type_code[2:1];
    wire [2:0] alignment_mask = width_bytes[2:0] - 3'd1;
    assign invalid_type = |type_code[63:3];
    assign misaligned = |(lane & alignment_mask);

    always @* begin
        case (type_code[2:1])
            2'd0: lane_mask = 8'h01;
            2'd1: lane_mask = 8'h03;
            2'd2: lane_mask = 8'h0f;
            2'd3: lane_mask = 8'hff;
        endcase
    end

    for (genvar byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin : mask_byte
        assign value_mask[8*byte_index +: 8] = {8{lane_mask[byte_index]}};
    end
endmodule
