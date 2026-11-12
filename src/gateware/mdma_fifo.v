// Each entry uses one FU handshake, including entries that bundle sibling results.
module mdma_fifo #(
    parameter integer IMPLEMENTATION = 0,
    parameter integer DEPTH = 4,
    parameter integer WIDTH = 64,
    parameter integer BYPASS = 1
) (
    input wire clk,
    input wire reset,
    input wire [WIDTH-1:0] i_in_data,
    input wire i_in_valid,
    output wire i_in_take,
    output wire [WIDTH-1:0] o_out_data,
    output wire o_out_valid,
    input wire o_out_take
);
    localparam integer INDEX_BITS = $clog2(DEPTH);
    localparam [INDEX_BITS-1:0] LAST = DEPTH - 1;
    localparam [INDEX_BITS:0] CAPACITY = DEPTH;

    reg [INDEX_BITS-1:0] read_index, write_index;
    reg [INDEX_BITS:0] used;
    wire pop = o_out_valid && o_out_take;
    wire push = i_in_take;
    wire [INDEX_BITS-1:0] next_read = read_index == LAST ? 0 : read_index + 1'b1;
    wire [INDEX_BITS-1:0] next_write = write_index == LAST ? 0 : write_index + 1'b1;

    assign o_out_valid = !reset && used != 0;
    // Full replacement can bypass the capacity check when a pop frees a slot.
    assign i_in_take = !reset && i_in_valid && (used != CAPACITY || (BYPASS && pop));

    always @(posedge clk) begin
        if (reset) begin
            used <= 0;
            read_index <= 0;
            write_index <= 0;
        end else begin
            if (push != pop)
                used <= push ? used + 1'b1 : used - 1'b1;
            if (push)
                write_index <= next_write;
            if (pop)
                read_index <= next_read;
        end
    end

    generate
        if (DEPTH < 4 || WIDTH < 1) begin : invalid_size
            initial $fatal(1, "mdma_fifo requires DEPTH >= 4 and WIDTH >= 1");
        end

        if (IMPLEMENTATION == 0) begin : register_storage
            (* ram_style = "logic" *) reg [WIDTH-1:0] entries [0:DEPTH-1];
            always @(posedge clk)
                if (push)
                    entries[write_index] <= i_in_data;
            assign o_out_data = entries[read_index];
        end else if (IMPLEMENTATION == 1) begin : lut_storage
            (* ram_style = "distributed" *) reg [WIDTH-1:0] entries [0:DEPTH-1];
            always @(posedge clk)
                if (push)
                    entries[write_index] <= i_in_data;
            assign o_out_data = entries[read_index];
        end else if (IMPLEMENTATION == 2) begin : block_storage
            (* ram_style = "block", no_rw_check *) reg [WIDTH-1:0] entries [0:DEPTH-1];
            wire [INDEX_BITS-1:0] fetch_index = pop ? next_read : read_index;
            reg [WIDTH-1:0] fetched, forwarded;
            reg forward;

            // Empty pushes and one-entry replacements collide with the
            // synchronous read. Use the written value regardless of RAM mode.
            always @(posedge clk) begin
                fetched <= entries[fetch_index];
                forward <= push && write_index == fetch_index;
                forwarded <= i_in_data;
                if (push)
                    entries[write_index] <= i_in_data;
            end
            assign o_out_data = forward ? forwarded : fetched;
        end else begin : invalid_implementation
            initial $fatal(1, "Unknown FIFO IMPLEMENTATION");
        end
    endgenerate
endmodule
