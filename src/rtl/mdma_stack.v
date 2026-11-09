module mdma_stack (
    input wire clk, reset, reserve, push, pop,
    input wire [63:0] data_in,
    output wire [63:0] top,
    output reg empty, full
);
    reg [4:0] used;
    reg [3:0] top_index;
    (* ram_style = "distributed" *) reg [63:0] entries [0:15];
    assign top = push ? data_in : entries[top_index];

    // The reservation has already set the top address for the incoming word.
    // If that word is also popped, the write lands in a slot no longer live.
    always @(posedge clk) begin
        if (push)
            entries[top_index] <= data_in;

        if (reset) begin
            used <= 0;
            top_index <= 15;
            empty <= 1;
            full <= 0;
        end else if (reserve != pop) begin
            used <= reserve ? used + 1'b1 : used - 1'b1;
            top_index <= reserve ? used[3:0] : top_index - 1'b1;
            empty <= pop && used == 1;
            full <= reserve && used == 15;
        end
    end
endmodule
