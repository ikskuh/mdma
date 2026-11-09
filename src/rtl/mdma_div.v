// One quotient bit per clock, using carry selection across four 16-bit subtractors.
module mdma_div #(parameter SIGNED_OP = 0) (
    input wire clk, reset, start,
    input wire [63:0] lhs, rhs,
    output reg done,
    output reg [63:0] quotient, residue
);
    localparam IDLE = 0, DIV_STEP = 1, SIGN = 2;
    reg [1:0] state;
    reg [6:0] rounds;
    reg [63:0] x, y, remainder;
    reg negate_quotient, negate_remainder;
    wire lhs_negative = SIGNED_OP && lhs[63];
    wire rhs_negative = SIGNED_OP && rhs[63];
    wire [64:0] trial = {remainder, x[63]};
    wire [3:0] borrow, generate_borrow, propagate_borrow;
    wire [63:0] difference;
    assign borrow[0] = 0;
    assign borrow[1] = generate_borrow[0];
    assign borrow[2] = generate_borrow[1] || (propagate_borrow[1] && generate_borrow[0]);
    assign borrow[3] = generate_borrow[2] || (propagate_borrow[2] && borrow[2]);
    wire subtract_trial = trial[64] || !(generate_borrow[3] || (propagate_borrow[3] && borrow[3]));

    genvar limb;
    for (limb = 0; limb < 4; limb = limb + 1) begin: subtract_limb
        wire [15:0] left = trial[16*limb +: 16];
        wire [15:0] right = y[16*limb +: 16];
        wire [16:0] direct = {1'b0, left} - {1'b0, right};
        wire [15:0] with_borrow = left + ~right;
        assign generate_borrow[limb] = direct[16];
        assign propagate_borrow[limb] = left == right;
        assign difference[16*limb +: 16] = borrow[limb] ? with_borrow : direct[15:0];
    end

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
                    remainder <= 0;
                    rounds <= 64;
                    negate_quotient <= lhs_negative ^ rhs_negative;
                    negate_remainder <= lhs_negative;
                    state <= DIV_STEP;
                end
                DIV_STEP: begin
                    x <= {x[62:0], subtract_trial};
                    remainder <= subtract_trial ? difference : trial[63:0];
                    rounds <= rounds - 1'b1;
                    state <= rounds == 1 ? SIGN : DIV_STEP;
                end
                SIGN: begin
                    quotient <= negate_quotient ? -x : x;
                    residue <= negate_remainder ? -remainder : remainder;
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
