module mdma_swizzle8(input wire [63:0] value, selector, output wire [63:0] result);
    genvar byte_index;
    for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin: select_byte
        assign result[byte_index*8 +: 8] = value[{selector[byte_index*3 +: 3], 3'b0} +: 8];
    end
endmodule
