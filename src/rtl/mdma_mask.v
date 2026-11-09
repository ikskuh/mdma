module mdma_mask(input wire [63:0] value, output wire [127:0] results);
    wire in_range = value[63:6] == 0;
    assign results[63:0] = in_range ? ~(64'hffffffffffffffff << value[5:0]) : 64'hffffffffffffffff;
    assign results[127:64] = in_range ? 64'd1 << value[5:0] : 64'b0;
endmodule
