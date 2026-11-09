// Each instance owns its memory and read/write pointers. A generation of
// sibling outputs is one entry, so its outputs share readiness and retirement.
module mdma_fifo #(
    parameter WIDTH = 64,
    parameter INDEX_BITS = 3,
    parameter BLOCK = 0
) (
    input wire clk, reset, push, pop, reserve,
    input wire [WIDTH-1:0] data_in,
    output wire [WIDTH-1:0] data_out,
    output wire [INDEX_BITS:0] count,
    output reg empty, full
);
    localparam DEPTH = 1 << INDEX_BITS;
    localparam [INDEX_BITS:0] LAST = DEPTH - 1;
    reg [INDEX_BITS:0] used;
    reg [INDEX_BITS-1:0] read_index, write_index;
    assign count = used;
    generate
        if (BLOCK) begin: block_storage
            // Fetch the next head at the pop edge. Forward a just-written
            // head explicitly so empty-to-nonempty takes one edge too.
            (* ram_style = "block", no_rw_check *) reg [WIDTH-1:0] entries [0:DEPTH-1];
            reg [WIDTH-1:0] fetched, forwarded;
            reg forward;
            wire [INDEX_BITS-1:0] next_read = pop ? read_index + 1'b1 : read_index;
            always @(posedge clk) begin
                fetched <= entries[next_read];
                forward <= push && write_index == next_read;
                forwarded <= data_in;
                if (push)
                    entries[write_index] <= data_in;
            end
            assign data_out = forward ? forwarded : fetched;
        end else begin: distributed_storage
            (* ram_style = "distributed" *) reg [WIDTH-1:0] entries [0:DEPTH-1];
            always @(posedge clk)
                if (push)
                    entries[write_index] <= data_in;
            assign data_out = entries[read_index];
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            used <= 0;
            empty <= 1;
            full <= 0;
            read_index <= 0;
            write_index <= 0;
        end else begin
            if (reserve != pop) begin
                used <= reserve ? used + 1'b1 : used - 1'b1;
                empty <= pop && used == 1;
                full <= reserve && used == LAST;
            end
            if (pop)
                read_index <= read_index + 1'b1;
            if (push)
                write_index <= write_index + 1'b1;
        end
    end
endmodule
