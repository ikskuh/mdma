`timescale 1ns/1ps
module mdma_stream_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1, flush = 0;
    reg [63:0] restart = 0;
    reg [1:0] pop = 0;
    wire [63:0] head, word0, word1, adr;
    wire [1:0] valid, error;
    wire [6:0] count;
    wire cyc, stb;
    integer clock = 0;
    wire stall = clock % 7 == 0;
    reg [63:0] requests [0:127];
    integer read_pointer = 0, write_pointer = 0, queued = 0;
    wire accept = cyc && stb && !stall;
    wire ack = cyc && queued != 0 && clock % 3 != 0;
    wire [63:0] response_address = requests[read_pointer];
    reg inject_error = 0;
    wire err = ack && inject_error && response_address == 64'h880;
    function [63:0] contents(input [63:0] address);
        contents = (address * 64'h9e3779b97f4a7c15) ^ 64'hfedcba9876543210;
    endfunction
    mdma_instruction_stream dut (
        .clk(clk), .reset(reset), .enable(1'b1), .flush(flush), .restart_address(restart),
        .pop_count(pop), .head_address(head), .word0(word0), .word1(word1),
        .valid(valid), .error(error), .count(count), .wb_cyc(cyc), .wb_stb(stb),
        .wb_adr(adr), .wb_stall(stall), .wb_dat(contents(response_address)),
        .wb_ack(ack && !err), .wb_err(err)
    );
    reg [63:0] expected_head = 0;
    integer consumed = 0, pairs = 0, full_seen = 0, fault_seen = 0;
    always @(posedge clk) begin
        clock <= clock + 1;
        if (reset || !cyc) begin
            queued <= 0;
            read_pointer <= 0;
            write_pointer <= 0;
        end else begin
            queued <= queued + accept - ack;
            if (accept) begin
                requests[write_pointer] <= adr;
                write_pointer <= (write_pointer + 1) % 128;
            end
            if (ack)
                read_pointer <= (read_pointer + 1) % 128;
        end
        if (reset)
            expected_head <= 0;
        else if (flush)
            expected_head <= restart;
        else begin
            if (head !== expected_head || pop > count || count + dut.outstanding > 64)
                $fatal(1, "stream address/capacity accounting");
            if (valid[0] && (word0 !== contents(expected_head) ||
                error[0] !== (inject_error && expected_head == 64'h880)))
                $fatal(1, "stream first word/error at %h: %h", head, word0);
            if (valid[1] && (word1 !== contents(expected_head + 8) ||
                error[1] !== (inject_error && expected_head + 8 == 64'h880)))
                $fatal(1, "stream second word/error at %h: %h", head, word1);
            expected_head <= expected_head + 8*pop;
            consumed <= consumed + pop;
            if (pop == 2) pairs <= pairs + 1;
            if (count == 64) full_seen <= full_seen + 1;
            if (valid[0] && error[0]) fault_seen <= fault_seen + 1;
        end
    end
    integer i;
    initial begin
        repeat (2) @(negedge clk);
        reset = 0;
        repeat (150) @(negedge clk);
        for (i = 0; i < 600; i = i + 1) begin
            pop = count >= 2 && i % 3 == 0 ? 2 : count != 0 && i % 5 != 0 ? 1 : 0;
            @(negedge clk);
        end
        // Flush with both queued words and outstanding responses. The slave
        // may still ACK on this edge; the FIFO must discard it.
        pop = 0;
        flush = 1;
        restart = 64'h800;
        inject_error = 1;
        @(negedge clk);
        flush = 0;
        for (i = 0; i < 160; i = i + 1) begin
            pop = count != 0 ? 1 : 0;
            @(negedge clk);
        end
        pop = 0;
        reset = 1;
        inject_error = 0;
        @(negedge clk);
        reset = 0;
        repeat (120) @(negedge clk);
        if (consumed < 200 || pairs == 0 || full_seen == 0 || fault_seen == 0 || count != 64)
            $fatal(1, "stream coverage: consumed=%d pairs=%d full=%d faults=%d count=%d",
                   consumed, pairs, full_seen, fault_seen, count);
        $display("PASS raw stream wraparound, pairs, credits, cancellation, errors, reset");
        $finish;
    end
    initial begin #30000; $fatal(1, "stream timeout"); end
endmodule
