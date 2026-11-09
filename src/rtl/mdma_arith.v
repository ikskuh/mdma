module mdma_arith(input wire [63:0] lhs, rhs, output wire [127:0] results);
    assign results[63:0] = lhs + rhs;
    assign results[127:64] = lhs - rhs;
endmodule
