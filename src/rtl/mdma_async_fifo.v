// Eight entries with Gray-coded pointers and a registered, show-ahead read.
// The two synchronization stages keep an entry invisible until its write
// has settled. Only pointers cross as asynchronous control signals.
module mdma_async_fifo #(parameter WIDTH = 64) (
    input wire write_clk, read_clk, reset, push, pop,
    input wire [WIDTH-1:0] write_data,
    output reg [WIDTH-1:0] read_data,
    output wire full, almost_full, empty,
    output wire [4:0] read_count, read_seen_write
);
    localparam [4:0] EMPTY_LIMIT_GRAY = 5'd8 ^ (5'd8 >> 1);
    reg [4:0] write_index, read_index, write_gray, read_gray, read_limit_gray;
    reg [4:0] write_ahead_gray;
    (* async_reg = "true" *) reg [4:0] read_sync1, read_sync2, write_sync1, write_sync2;
    (* async_reg = "true" *) reg [1:0] write_reset, read_reset;

    always @(posedge write_clk or posedge reset)
        if (reset) write_reset <= 2'b11; else write_reset <= {write_reset[0], 1'b0};
    always @(posedge read_clk or posedge reset)
        if (reset) read_reset <= 2'b11; else read_reset <= {read_reset[0], 1'b0};

    function [4:0] binary(input [4:0] gray);
        binary = {gray[4], ^gray[4:3], ^gray[4:2], ^gray[4:1], ^gray};
    endfunction

    wire write_advance = push && !full;
    wire read_advance = pop && !empty;
    wire [4:0] write_next = write_index + 1'b1;
    wire [4:0] write_ahead = write_index + 5'd2;
    wire [4:0] read_next = read_index + 1'b1;
    wire [4:0] read_limit = read_next + 5'd8;
    wire [2:0] read_address = read_advance ? read_next[2:0] : read_index[2:0];
    (* ram_style = "distributed" *) reg [WIDTH-1:0] entries [0:7];
    always @(posedge write_clk)
        if (write_advance)
            entries[write_index[2:0]] <= write_data;
    assign read_seen_write = binary(write_sync2);
    assign read_count = read_seen_write - read_index;
    // The read domain sends the next full boundary in Gray code. Both
    // readiness flags are local comparisons of synchronized Gray pointers.
    assign full = write_reset[1] || write_gray == read_sync2;
    assign almost_full = write_ahead_gray == read_sync2;
    assign empty = read_reset[1] || read_gray == write_sync2;

    always @(posedge write_clk) begin
        if (write_reset[1]) begin
            write_index <= 0;
            write_gray <= 0;
            write_ahead_gray <= 1;
            read_sync1 <= EMPTY_LIMIT_GRAY;
            read_sync2 <= EMPTY_LIMIT_GRAY;
        end else begin
            read_sync1 <= read_limit_gray;
            read_sync2 <= read_sync1;
            if (write_advance) begin
                write_index <= write_next;
                write_gray <= write_next ^ (write_next >> 1);
                write_ahead_gray <= write_ahead ^ (write_ahead >> 1);
            end
        end
    end

    always @(posedge read_clk) begin
        if (read_reset[1]) begin
            read_index <= 0;
            read_gray <= 0;
            read_limit_gray <= EMPTY_LIMIT_GRAY;
            write_sync1 <= 0;
            write_sync2 <= 0;
        end else begin
            write_sync1 <= write_gray;
            write_sync2 <= write_sync1;
            if (read_advance) begin
                read_index <= read_next;
                read_gray <= read_next ^ (read_next >> 1);
                read_limit_gray <= read_limit ^ (read_limit >> 1);
            end
        end
        read_data <= entries[read_address];
    end
endmodule
