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
    reg pause_replies = 0, force_stall = 0;
    wire stall = force_stall || clock % 7 == 0;
    reg [63:0] requests [0:127];
    integer read_pointer = 0, write_pointer = 0, queued = 0;
    wire accept = cyc && stb && !stall;
    reg force_reply = 0;
    wire ack = cyc && queued != 0 && !pause_replies && (force_reply || clock % 3 != 0);
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
    integer reads = 0, hits = 0, misses = 0;
    reg stalled = 0;
    reg [63:0] stalled_address;
    always @(posedge clk) begin
        if (reset) stalled <= 0;
        else begin
            if (stalled && cyc && (!stb || adr !== stalled_address))
                $fatal(1, "stalled request changed before cancellation");
            stalled <= cyc && stb && stall;
            stalled_address <= adr;
            if (accept) reads <= reads + 1;
            if (dut.redirect_hit) hits <= hits + 1;
            if (dut.restart) misses <= misses + 1;
            if (dut.evict && dut.history <= dut.HISTORY_WORDS)
                $fatal(1, "reserved a request by evicting protected history");
        end
    end
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
        else if (!dut.redirect_lookup) begin
            if (head !== expected_head || pop > count || dut.occupied > dut.WORDS)
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
            if (count == dut.WORDS) full_seen <= full_seen + 1;
            if (valid[0] && error[0]) fault_seen <= fault_seen + 1;
        end
    end
    task seek(input [63:0] address);
        begin
            pop = 0;
            restart = address;
            flush = 1;
            @(negedge clk);
            flush = 0;
            @(negedge clk);
            if (head !== address)
                $fatal(1, "redirect wanted %h, got %h", address, head);
        end
    endtask

    integer i, lap, before_reads, before_hits, before_misses;
    initial begin
        repeat (2) @(negedge clk);
        reset = 0;
        wait (count == dut.WORDS);
        @(negedge clk);
        before_reads = reads;
        before_hits = hits;
        for (lap = 0; lap < 4; lap = lap + 1) begin
            repeat (dut.HISTORY_WORDS) begin
                pop = 1;
                @(negedge clk);
            end
            seek(0);
            if (!cyc || !valid[0] || reads != before_reads)
                $fatal(1, "resident loop refetched its body");
        end
        seek(8);
        if (hits - before_hits != 5 || word0 !== contents(8))
            $fatal(1, "resident forward skip");
        // Evict the oldest word while holding the replacement request.
        force_stall = 1;
        repeat (dut.HISTORY_WORDS) begin
            pop = 1;
            @(negedge clk);
        end
        pop = 0;
        wait (stb);
        @(negedge clk);
        seek(8);
        if (!cyc || !stb || !valid[0])
            $fatal(1, "resident redirect lost a stalled request");
        before_misses = misses;
        seek(0);
        if (misses != before_misses + 1 || cyc)
            $fatal(1, "evicted word incorrectly reused");
        force_stall = 0;
        // A different upper address with identical ring-index bits misses.
        wait (valid[0]);
        @(negedge clk);
        before_misses = misses;
        seek(64'h100000000 + 8*(dut.WORDS-1));
        if (misses != before_misses + 1)
            $fatal(1, "redirect aliased high address bits");
        wait (count >= 2);
        @(negedge clk);
        pause_replies = 1;
        wait (queued != 0);
        @(negedge clk);
        // Resolve a hit and a miss with an ACK on their lookup edge.
        restart = head;
        flush = 1;
        @(negedge clk);
        flush = 0;
        pause_replies = 0;
        force_reply = 1;
        @(negedge clk);
        if (!valid[1] || !cyc)
            $fatal(1, "hit with concurrent reply");
        pop = 2;
        @(negedge clk);
        pop = 0;
        force_reply = 0;
        for (i = 0; i < 600; i = i + 1) begin
            pop = count >= 2 && i % 3 == 0 ? 2 : count != 0 && i % 5 != 0 ? 1 : 0;
            @(negedge clk);
        end
        // Flush with both queued words and outstanding responses. The slave
        // may still ACK on this edge; the FIFO must discard it.
        pop = 0;
        pause_replies = 1;
        while (queued == 0) begin
            pop = valid[0] ? 1 : 0;
            @(negedge clk);
        end
        pop = 0;
        restart = 64'h800;
        flush = 1;
        inject_error = 1;
        @(negedge clk);
        flush = 0;
        pause_replies = 0;
        force_reply = 1;
        @(negedge clk);
        force_reply = 0;
        if (cyc || count != 0)
            $fatal(1, "miss retained a concurrent reply");
        for (i = 0; i < 160; i = i + 1) begin
            pop = count != 0 ? 1 : 0;
            @(negedge clk);
        end
        // Skip an error token by seeking to a later word already received.
        // Refill must resume even though that error stopped the old fetch.
        pause_replies = 1;
        seek(64'h4000);
        seek(64'h880);
        wait (queued >= 3);
        @(negedge clk);
        pause_replies = 0;
        wait (count >= 3 && dut.outstanding == 0 && !dut.request_pending);
        @(negedge clk);
        seek(64'h888);
        if (!valid[0] || error[0] || !cyc)
            $fatal(1, "speculative error survived a redirect to a later word");
        before_reads = reads;
        repeat (24) @(negedge clk);
        if (reads <= before_reads)
            $fatal(1, "resident redirect left fetch stopped by an earlier error");
        pop = 0;
        reset = 1;
        inject_error = 0;
        @(negedge clk);
        reset = 0;
        repeat (120) @(negedge clk);
        if (consumed < 200 || pairs == 0 || full_seen == 0 || fault_seen == 0 || count != dut.WORDS)
            $fatal(1, "stream coverage: consumed=%d pairs=%d full=%d faults=%d count=%d",
                   consumed, pairs, full_seen, fault_seen, count);
        $display("PASS raw stream wraparound, pairs, credits, cancellation, errors, reset");
        $finish;
    end
    initial begin #30000; $fatal(1, "stream timeout"); end
endmodule
