module mdma_stash (
    input wire clk, reset, reserve, push, pop,
    input wire [63:0] data_in,
    output wire [63:0] data_out,
    output wire empty, full
);
    wire [4:0] used;
    wire [63:0] stored_head;
    // Count a write when dispatch reserves it. The RAM writes one edge later.
    mdma_fifo #(.INDEX_BITS(4)) entries (
        .clk(clk), .reset(reset), .reserve(reserve), .push(push), .pop(pop), .data_in(data_in),
        .data_out(stored_head), .empty(empty), .full(full), .count(used)
    );
    assign data_out = push && used == 1 ? data_in : stored_head;
endmodule
