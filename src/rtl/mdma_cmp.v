module mdma_cmp(input wire [63:0] lhs, rhs, output wire [383:0] results);
    wire equal = lhs == rhs;
    wire below = lhs < rhs;
    wire less = lhs[63] == rhs[63] ? below : lhs[63];
    assign results[63:0] = {63'b0, equal};
    assign results[127:64] = {63'b0, below};
    assign results[191:128] = {63'b0, less};
    assign results[255:192] = {63'b0, below || equal};
    assign results[319:256] = {63'b0, less || equal};
    assign results[383:320] = {63'b0, !equal};
endmodule
