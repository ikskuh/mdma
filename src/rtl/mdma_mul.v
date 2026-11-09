// Four parallel partial products map to the ECP5 DSP multipliers.
module mdma_mul #(parameter SIGNED_OP = 0) (
    input wire clk, reset, start,
    input wire [63:0] lhs, rhs,
    output reg done,
    output reg [63:0] lo, hi
);
    localparam IDLE = 0, PARTIALS = 1, CROSS = 2, PRODUCT_LOW = 3, PRODUCT_HIGH = 4, SIGN = 5;
    reg [2:0] state;
    reg [63:0] x, y, product_low, product_high;
    reg [63:0] p00, p01, p10, p11;
    reg [64:0] cross_product;
    reg carry, negate;
    wire lhs_negative = SIGNED_OP && lhs[63];
    wire rhs_negative = SIGNED_OP && rhs[63];

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            done <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    x <= lhs_negative ? -lhs : lhs;
                    y <= rhs_negative ? -rhs : rhs;
                    negate <= lhs_negative ^ rhs_negative;
                    state <= PARTIALS;
                end
                PARTIALS: begin
                    p00 <= x[31:0] * y[31:0];
                    p01 <= x[31:0] * y[63:32];
                    p10 <= x[63:32] * y[31:0];
                    p11 <= x[63:32] * y[63:32];
                    state <= CROSS;
                end
                CROSS: begin
                    cross_product <= {1'b0, p01} + {1'b0, p10};
                    state <= PRODUCT_LOW;
                end
                PRODUCT_LOW: begin
                    {carry, product_low} <= {1'b0, p00} + {1'b0, cross_product[31:0], 32'b0};
                    state <= PRODUCT_HIGH;
                end
                PRODUCT_HIGH: begin
                    product_high <= p11 + {31'b0, cross_product[64:32]} + carry;
                    state <= SIGN;
                end
                SIGN: begin
                    lo <= negate ? -product_low : product_low;
                    hi <= negate ? (~product_high + (product_low == 0)) : product_high;
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
