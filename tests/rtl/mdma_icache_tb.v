`timescale 1ns/1ps
module mdma_icache_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1, cyc = 0, stb = 0;
    reg [63:0] adr = 0;
    wire stall, ack, err, m_cyc, m_stb;
    wire [63:0] data, m_adr;
    reg hold_backend = 0, inject_error = 0;
    integer delay = 0, backend_reads = 0;
    wire m_done = m_cyc && !hold_backend && delay == 3;
    function [63:0] contents(input [63:0] address);
        contents = address ^ 64'h0123456789abcdef;
    endfunction
    mdma_icache dut (
        .clk(clk), .reset(reset), .s_cyc(cyc), .s_stb(stb), .s_adr(adr),
        .s_stall(stall), .s_dat(data), .s_ack(ack), .s_err(err),
        .wb_cyc(m_cyc), .wb_stb(m_stb), .wb_adr(m_adr), .wb_dat(contents(m_adr)),
        .wb_ack(m_done && !inject_error), .wb_err(m_done && inject_error)
    );
    always @(posedge clk) begin
        if (reset || !m_cyc || m_done) delay <= 0;
        else if (!hold_backend) delay <= delay + 1;
        if (!reset && m_done) backend_reads <= backend_reads + 1;
    end
    reg [63:0] expected [0:511];
    integer sent = 0, received = 0, clock = 0, last_reply = -10, consecutive = 0;
    reg expect_error = 0, check_hot_latency = 0;
    integer accepted_clock [0:511];
    always @(posedge clk) if (!reset) begin
        clock = clock + 1;
        if (cyc && stb && !stall) begin
            expected[sent] = adr;
            accepted_clock[sent] = clock;
            sent = sent + 1;
        end
        if (ack || err) begin
            if (!cyc || received >= sent || err !== expect_error || (ack && data !== contents(expected[received])))
                $fatal(1, "cache response/order received=%d sent=%d got=%h", received, sent, data);
            if (check_hot_latency && clock - accepted_clock[received] != 1)
                $fatal(1, "cache hit introduced a queue cycle");
            received = received + 1;
            if (clock == last_reply + 1) consecutive = consecutive + 1;
            last_reply = clock;
        end
    end
    task send(input [63:0] address);
        begin
            adr = address;
            stb = 1;
            @(posedge clk);
            while (stall) @(posedge clk);
            @(negedge clk);
            stb = 0;
        end
    endtask
    task drain;
        begin while (received < sent) @(negedge clk); end
    endtask
    task cancel;
        begin
            cyc = 0;
            stb = 0;
            @(negedge clk);
            sent = received;
            cyc = 1;
        end
    endtask
    integer i, before_reads, before_received;
    initial begin
        repeat (2) @(negedge clk);
        reset = 0;
        cyc = 1;
        // Fill several partial lines, including both ways of the same set.
        for (i = 0; i < 16; i = i + 1) send(i*8);
        send(64'h800);
        drain;
        before_reads = backend_reads;
        consecutive = 0;
        check_hot_latency = 1;
        // Continuous pipelined hit stream: no backend access and one reply/clock.
        for (i = 0; i < 40; i = i + 1) send((i%16)*8);
        drain;
        check_hot_latency = 0;
        if (backend_reads != before_reads || consecutive < 35)
            $fatal(1, "cache hot throughput: reads=%d consecutive=%d", backend_reads-before_reads, consecutive);
        // Third competing line evicts one way. Returned data must retain tags.
        send(64'h1000); send(0); send(64'h800); drain;
        send(0); drain;
        // Cancel an active miss. A new cached hit must finish while the old
        // backend beat is held, then its eventual error must be ignored.
        hold_backend = 1;
        send(64'h1800);
        while (!m_cyc) @(negedge clk);
        cancel;
        before_received = received;
        send(0); drain;
        if (received != before_received + 1 || !m_cyc)
            $fatal(1, "target hit did not bypass canceled miss");
        inject_error = 1;
        hold_backend = 0;
        while (m_cyc) @(negedge clk);
        repeat (3) @(negedge clk);
        inject_error = 0;
        send(0); drain;
        // An uncanceled backend error is returned once, without caching it.
        inject_error = 1;
        expect_error = 1;
        send(64'h2000); drain;
        expect_error = 0;
        inject_error = 0;
        send(64'h2000); drain;
        // Cancel on the exact completion edge, including queued frontend work.
        hold_backend = 1;
        send(64'h2800); send(64'h2808);
        while (!m_cyc) @(negedge clk);
        hold_backend = 0;
        while (!m_done) @(negedge clk);
        cancel;
        send(64'h2000); drain;
        // Full-width tags must not alias above the physical board address.
        send(64'h100000000); send(64'h2000); drain;
        // Reset also discards a live miss and its queued frontend requests.
        hold_backend = 1;
        send(64'h3000); send(64'h3008);
        while (!m_cyc) @(negedge clk);
        reset = 1;
        cyc = 0;
        @(negedge clk);
        reset = 0;
        hold_backend = 0;
        sent = received;
        cyc = 1;
        before_reads = backend_reads;
        send(64'h2000); drain;
        if (backend_reads != before_reads + 1)
            $fatal(1, "cache reset retained a valid line");
        $display("PASS bus cache pipelining, tags, replacement, cancellation, errors, reset");
        $finish;
    end
    initial begin #100000; $fatal(1, "cache timeout sent=%d received=%d", sent, received); end
endmodule
