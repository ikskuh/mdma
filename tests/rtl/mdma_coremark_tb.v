`timescale 1ns/1ps

// Board RTL with asynchronous SRAM and all domains at the same frequency.
module mdma_coremark_tb;
    localparam WORDS = 131072;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    wire halted, cs_n, oe_n, we_n;
    wire [3:0] fault;
    wire [31:0] address;
    wire [63:0] data;
    reg [63:0] memory [0:WORDS-1];

    mdma_ecp5 board (
        .clk(clk), .mem_clk(clk), .math_clk({4{clk}}), .reset(reset),
        .serial_rx(1'b1), .serial_tx(), .halted(halted), .fault(fault),
        .sram_a(address), .sram_d(data), .sram_cs_n(cs_n), .sram_oe_n(oe_n), .sram_we_n(we_n)
    );
    assign data = !cs_n && !oe_n && we_n ? memory[address[16:0]] : 64'bz;
    always @(negedge clk) begin
        if (!cs_n && address >= WORDS)
            $fatal(1, "SRAM address outside image memory: %h", address);
        if (!cs_n && !we_n)
            memory[address[16:0]] <= data;
    end

    reg [4095:0] image;
    reg [63:0] start_pc, end_pc;
    integer words, list_word, matrix_word, state_word, result_word;
    integer clocks = 0, start_clock = -1, end_clock = -1;
    integer fetch_clocks = 0, retire_clocks = 0, waiting_clocks = 0;
    integer refill_clocks = 0, unready_clocks = 0, ready_clocks = 0;
    integer refill_words = 0, redirects = 0, data_reads = 0, data_writes = 0;

    integer fetched_words = 0, cache_hits = 0, cache_misses = 0, cache_lookups = 0, refill_requests = 0;
    integer const_stalls = 0, instruction_stalls = 0, redirect_stalls = 0;
    integer execute_waits = 0, decode_bubbles = 0, const_fifo_empty = 0;
    integer const_stall_events = 0, instruction_stall_events = 0;
    reg previous_const_stall = 0, previous_instruction_stall = 0;
    wire lookup_hit =
        (board.soc.icache.match0 && board.soc.icache.valid0[board.soc.icache.index][board.soc.icache.address[4:3]]) ||
        (board.soc.icache.match1 && board.soc.icache.valid1[board.soc.icache.index][board.soc.icache.address[4:3]]);
    wire [4:0] constant_unblocks;
    genvar move_index;
    generate for (move_index = 0; move_index < 5; move_index = move_index + 1) begin: const_readiness
        assign constant_unblocks[move_index] = board.soc.cpu.src[move_index] == 1 &&
            !board.soc.cpu.move[move_index].sink_full && !board.soc.cpu.bad_sink[move_index];
    end endgenerate
    wire ready_except_constant =
        ((board.soc.cpu.ready_moves | constant_unblocks) & board.soc.cpu.pending) == board.soc.cpu.pending;
    // Attribute a lost retirement to CONST only when every other requirement
    // is ready. A simultaneous FU/predicate wait remains an execute wait.
    wire const_stall = board.soc.cpu.pending_constant && !board.soc.cpu.done &&
        (board.soc.cpu.skip || (board.soc.cpu.issue && ready_except_constant));
    wire instruction_stall = !board.soc.cpu.execute_valid && !board.soc.cpu.fetch_accept &&
        !board.soc.cpu.stream.cancel_cycle;
    integer stream_full = 0, stream_highwater = 0, constant_wait = 0;
    integer redirect_clock = 0, redirect_to_admit_total = 0, redirect_to_admit_max = 0;
    reg redirect_waiting = 0;

    initial begin
        if (!$value$plusargs("image=%s", image) || !$value$plusargs("words=%d", words) ||
            !$value$plusargs("start_pc=%d", start_pc) || !$value$plusargs("end_pc=%d", end_pc) ||
            !$value$plusargs("list_word=%d", list_word) || !$value$plusargs("matrix_word=%d", matrix_word) ||
            !$value$plusargs("state_word=%d", state_word) || !$value$plusargs("result_word=%d", result_word) ||
            words < 1 || words > WORDS)
            $fatal(1, "missing CoreMark image or labels");
        $readmemh(image, memory, 0, words - 1);
        repeat (3) @(negedge clk);
        reset = 0;
    end

    always @(posedge clk) if (!reset) begin
        if (fault != 0)
            $fatal(1, "CoreMark fault %d at PC %h after %d clocks", fault, board.soc.cpu.pc, clocks);
        if (board.soc.cpu.execute_valid) begin
            if (board.soc.cpu.pc == start_pc && start_clock < 0)
                start_clock = clocks;
            if (board.soc.cpu.pc == end_pc && end_clock < 0)
                end_clock = clocks;
        end
        if (start_clock >= 0 && end_clock < 0) begin
            if (board.soc.icache.wb_cyc && board.soc.icache.wb_ack)
                refill_words = refill_words + 1;
            if (board.soc.cpu.i_wb_cyc && board.soc.cpu.i_wb_ack)
                fetched_words = fetched_words + 1;
            // Classify each lookup once, including speculative/canceled work.
            if (board.soc.icache.lookup) begin
                cache_lookups = cache_lookups + 1;
                if (lookup_hit) cache_hits = cache_hits + 1;
                else cache_misses = cache_misses + 1;
            end
            if (board.soc.icache.miss_start)
                refill_requests = refill_requests + 1;
            if (board.soc.cpu.pending_constant && !board.soc.cpu.stream_valid[0])
                const_fifo_empty = const_fifo_empty + 1;
            if (const_stall && !previous_const_stall)
                const_stall_events = const_stall_events + 1;
            if (instruction_stall && !previous_instruction_stall)
                instruction_stall_events = instruction_stall_events + 1;
            previous_const_stall = const_stall;
            previous_instruction_stall = instruction_stall;
            // Disjoint clock accounting: exactly one category each clock.
            if (board.soc.cpu.execute_valid) begin
                if (!board.soc.cpu.done) begin
                    if (const_stall) const_stalls = const_stalls + 1;
                    else execute_waits = execute_waits + 1;
                end
            end else if (board.soc.cpu.fetch_accept)
                decode_bubbles = decode_bubbles + 1;
            else if (board.soc.cpu.stream.cancel_cycle)
                redirect_stalls = redirect_stalls + 1;
            else
                instruction_stalls = instruction_stalls + 1;
            if (board.soc.cpu.stream_count == 64)
                stream_full = stream_full + 1;
            if (board.soc.cpu.stream_count > stream_highwater)
                stream_highwater = board.soc.cpu.stream_count;
            if (board.soc.cpu.pending_constant)
                constant_wait = constant_wait + 1;
            if (board.soc.cpu.redirect) begin
                redirects = redirects + 1;
                redirect_clock = clocks;
                redirect_waiting = 1;
            end else if (redirect_waiting && board.soc.cpu.fetch_accept) begin
                redirect_waiting = 0;
                redirect_to_admit_total = redirect_to_admit_total + clocks - redirect_clock;
                if (clocks - redirect_clock > redirect_to_admit_max)
                    redirect_to_admit_max = clocks - redirect_clock;
            end
            if (board.soc.cpu.d_wb_cyc && board.soc.cpu.d_wb_ack) begin
                if (board.soc.cpu.d_wb_we)
                    data_writes = data_writes + 1;
                else
                    data_reads = data_reads + 1;
            end
            if (!board.soc.cpu.execute_valid) begin
                fetch_clocks = fetch_clocks + 1;
                if (board.soc.icache.busy)
                    refill_clocks = refill_clocks + 1;
                else if (!board.soc.cpu.stream_valid[0])
                    unready_clocks = unready_clocks + 1;
                else
                    ready_clocks = ready_clocks + 1;
            end else if (board.soc.cpu.done)
                retire_clocks = retire_clocks + 1;
            else
                waiting_clocks = waiting_clocks + 1;
        end
        if (halted) begin
            if (start_clock < 0 || end_clock <= start_clock)
                $fatal(1, "CoreMark timing boundaries were not reached");
            if (fetch_clocks + retire_clocks + waiting_clocks != end_clock - start_clock)
                $fatal(1, "CoreMark profile does not cover the timed interval");
            if (retire_clocks + const_stalls + execute_waits + instruction_stalls +
                redirect_stalls + decode_bubbles != end_clock - start_clock)
                $fatal(1, "instruction throughput counters overlap or omit clocks");
            if (cache_hits + cache_misses != cache_lookups)
                $fatal(1, "cache lookup counters do not partition accesses");
            if (const_stalls > constant_wait || const_stall_events > const_stalls ||
                instruction_stall_events > instruction_stalls)
                $fatal(1, "invalid instruction stall accounting");
            $display("PROFILE clocks=%0d cache_lookups=%0d refill_requests=%0d", end_clock - start_clock,
                     cache_lookups, refill_requests);
            $display("PROFILE const_stall=%0d instruction_stall=%0d redirect_stall=%0d execute_wait=%0d decode_bubble=%0d",
                     const_stalls, instruction_stalls, redirect_stalls, execute_waits, decode_bubbles);
            $display("PROFILE const_fifo_empty=%0d const_stall_events=%0d instruction_stall_events=%0d",
                     const_fifo_empty, const_stall_events, instruction_stall_events);
            $display("PROFILE empty_execute=%0d retired=%0d waiting=%0d",
                     fetch_clocks, retire_clocks, waiting_clocks);
            $display("PROFILE fetch_refill=%0d fetch_unready=%0d fetch_ready=%0d",
                     refill_clocks, unready_clocks, ready_clocks);
            $display("PROFILE refill_words=%0d redirects=%0d data_reads=%0d data_writes=%0d",
                     refill_words, redirects, data_reads, data_writes);
            $display("PROFILE fetched_words=%0d cache_hits=%0d cache_misses=%0d stream_full=%0d stream_highwater=%0d constant_wait=%0d",
                     fetched_words, cache_hits, cache_misses, stream_full, stream_highwater, constant_wait);
            $display("PROFILE redirect_to_admit_total=%0d redirect_to_admit_max=%0d",
                     redirect_to_admit_total, redirect_to_admit_max);
            $display("COREMARK %0d %0d %h %h %h %h", end_clock - start_clock, clocks,
                     memory[list_word], memory[matrix_word], memory[state_word], memory[result_word]);
            $finish;
        end
        if (clocks == 500000000)
            $fatal(1, "CoreMark timed out at PC %h", board.soc.cpu.pc);
        clocks = clocks + 1;
    end
endmodule
