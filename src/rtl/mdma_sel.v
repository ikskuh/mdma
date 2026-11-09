module mdma_sel(input wire [63:0] condition, when_true, when_false, output wire [63:0] result);
    assign result = condition != 0 ? when_true : when_false;
endmodule
