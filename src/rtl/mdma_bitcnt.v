module mdma_bitcnt(input wire [63:0] value, output wire [191:0] results);
    wire [6:0] popcount [1:127];
    genvar bit_index;
    for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin: leaf
        assign popcount[64+bit_index] = {6'b0, value[bit_index]};
    end
    for (bit_index = 1; bit_index < 64; bit_index = bit_index + 1) begin: sum
        assign popcount[bit_index] = popcount[bit_index*2] + popcount[bit_index*2+1];
    end

    reg [6:0] leading, trailing;
    integer i;
    always @* begin
        leading = 64;
        trailing = 64;
        for (i = 0; i < 64; i = i + 1) begin
            if (value[i])
                leading = 63 - i;
            if (value[63-i])
                trailing = 63 - i;
        end
    end
    assign results = {57'b0, trailing, 57'b0, leading, 57'b0, popcount[1]};
endmodule
