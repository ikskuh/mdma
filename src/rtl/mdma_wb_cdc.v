// One outstanding Wishbone Classic transaction on the CPU side. The
// request stays at the memory FIFO head until the slave acknowledges it.
module mdma_wb_cdc #(parameter REQUEST_WIDTH = 32) (
    input wire cpu_clk, mem_clk, reset, mem_reset,
    input wire request,
    input wire [REQUEST_WIDTH-1:0] payload,
    output wire ack, complete,
    output wire [63:0] response,
    output wire mem_request,
    output wire [REQUEST_WIDTH-1:0] mem_payload,
    input wire mem_ack,
    input wire [63:0] mem_response
);
    reg pending, retire_request;
    wire request_full, request_empty, response_full, response_empty;
    wire send = request && !pending && !request_full;
    assign complete = pending && !response_empty;
    assign ack = request && complete;
    assign mem_request = !request_empty && !response_full && !retire_request;

    always @(posedge cpu_clk) begin
        if (reset)
            pending <= 0;
        else if (send || complete)
            pending <= send;
    end

    // Return the response on ACK. Pop the old request on the next memory
    // edge, while the CPU is still waiting for the response to cross.
    always @(posedge mem_clk) begin
        if (mem_reset)
            retire_request <= 0;
        else
            retire_request <= mem_ack;
    end

    mdma_async_fifo #(.WIDTH(REQUEST_WIDTH)) requests (
        .write_clk(cpu_clk), .read_clk(mem_clk), .reset(reset),
        .push(send), .pop(retire_request), .write_data(payload), .read_data(mem_payload),
        .full(request_full), .empty(request_empty), .read_count(), .read_seen_write()
    );
    mdma_async_fifo responses (
        .write_clk(mem_clk), .read_clk(cpu_clk), .reset(reset),
        .push(mem_ack), .pop(complete), .write_data(mem_response), .read_data(response),
        .full(response_full), .empty(response_empty), .read_count(), .read_seen_write()
    );
endmodule
