module mdma_uop(input wire [63:0] value, output wire [191:0] results);
    wire [63:0] reversed;
    genvar byte_index;
    for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin: reverse_bytes
        assign reversed[byte_index*8 +: 8] = value[(7-byte_index)*8 +: 8];
    end
    assign results[63:0] = -value;
    assign results[127:64] = ~value;
    assign results[191:128] = reversed;
endmodule
