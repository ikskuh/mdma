// Store tuples are admitted together. Request order is recorded when
// operands first become ready, including while the data bus is busy.
module mdma_mem (
    input wire clk, reset, enable,
    input wire [3:0] read_count, write_count, data_count, mask_count,
    input wire [63:0] read_head, write_head, data_head, mask_head,
    output wire take_read, take_store,
    input wire output_full,
    output wire publish, progress, bus_fault,
    output wire [63:0] result,
    output wire wb_cyc, wb_stb,
    output wire wb_we,
    output reg [7:0] wb_sel,
    output reg [63:0] wb_adr,
    output wire [63:0] wb_dat_o,
    input wire [63:0] wb_dat_i,
    input wire wb_ack, wb_err
);
    localparam IDLE = 0, READ = 1, WRITE = 2, RESULT = 3;
    reg [1:0] state;
    reg [3:0] queued_reads, queued_stores;
    reg [1:0] request;
    reg [63:0] write_address, write_data, read_data;
    reg [7:0] byte_mask;
    wire [1:0] next_request;
    wire empty, full;

    wire new_read = read_count > queued_reads;
    wire new_store = write_count > queued_stores && data_count > queued_stores && mask_count > queued_stores;
    wire queue_request = enable && (new_read || new_store) && !full;
    wire start = enable && state == IDLE && !empty && (!next_request[1] || !output_full);

    mdma_fifo #(.WIDTH(2), .INDEX_BITS(4)) requests (
        .clk(clk), .reset(reset), .reserve(queue_request), .push(queue_request), .pop(start),
        .data_in({new_read, new_store}), .data_out(next_request),
        .empty(empty), .full(full), .count()
    );
    assign take_read = start && next_request[1];
    assign take_store = start && next_request[0];
    assign wb_cyc = enable && (state == READ || state == WRITE);
    assign wb_stb = wb_cyc;
    assign wb_we = state == WRITE;
    assign wb_dat_o = write_data;
    assign publish = enable && state == RESULT;
    assign result = read_data;
    assign bus_fault = wb_cyc && wb_err;
    assign progress = queue_request || start || state != IDLE;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            queued_reads <= 0;
            queued_stores <= 0;
        end else if (enable) begin
            queued_reads <= queued_reads + (queue_request && new_read) - take_read;
            queued_stores <= queued_stores + (queue_request && new_store) - take_store;
            case (state)
                IDLE: if (start) begin
                    request <= next_request;
                    wb_adr <= next_request[1] ? {read_head[63:3], 3'b0} : {write_head[63:3], 3'b0};
                    write_address <= {write_head[63:3], 3'b0};
                    write_data <= data_head;
                    byte_mask <= mask_head[7:0];
                    wb_sel <= next_request[1] ? 8'hff : ~mask_head[7:0];
                    state <= next_request[1] ? READ : WRITE;
                end
                READ: if (wb_ack && !wb_err) begin
                    read_data <= wb_dat_i;
                    if (request[0]) begin
                        wb_adr <= write_address;
                        wb_sel <= ~byte_mask;
                    end
                    state <= request[0] ? WRITE : RESULT;
                end
                WRITE: if (wb_ack && !wb_err) begin
                    state <= request[1] ? RESULT : IDLE;
                end
                RESULT: state <= IDLE;
            endcase
        end
    end
endmodule
