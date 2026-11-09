module mdma_unpack(input wire [63:0] address, kind, chunk, output reg [63:0] result);
    wire [63:0] value = chunk >> {address[2:0], 3'b0};
    always @* begin
        case (kind[2:1])
            0: result = {{56{kind[0] && value[7]}}, value[7:0]};
            1: result = {{48{kind[0] && value[15]}}, value[15:0]};
            2: result = {{32{kind[0] && value[31]}}, value[31:0]};
            default: result = value;
        endcase
    end
endmodule
