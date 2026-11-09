module mdma_logic(input wire [63:0] lhs, rhs, output wire [191:0] results);
    assign results = {lhs ^ rhs, lhs | rhs, lhs & rhs};
endmodule
