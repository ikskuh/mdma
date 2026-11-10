`timescale 1ns/1ps

// Board RTL with on-chip BRAM. Math clocks match the CPU in this benchmark.
module mdma_coremark_tb;
    localparam WORDS = 32768;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    wire halted;
    wire [3:0] fault;

    mdma_ecp5 board (
        .clk(clk), .math_clk({4{clk}}), .reset(reset),
        .serial_rx(1'b1), .serial_tx(), .halted(halted), .fault(fault)
    );

    reg [4095:0] image;
    reg [63:0] start_pc, end_pc;
    integer words, list_word, matrix_word, state_word, result_word;
    integer clocks = 0, start_clock = -1, end_clock = -1;
    integer fetch_clocks = 0, retire_clocks = 0, waiting_clocks = 0;
    integer unready_clocks = 0, ready_clocks = 0;
    integer redirects = 0, data_reads = 0, data_writes = 0, instruction_reads = 0, instruction_port_wait = 0;

    integer const_stalls = 0, instruction_stalls = 0, redirect_stalls = 0;
    integer execute_waits = 0, decode_bubbles = 0, const_fifo_empty = 0;
    integer const_stall_events = 0, instruction_stall_events = 0;
    reg previous_const_stall = 0, previous_instruction_stall = 0;
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
    wire redirect_busy = board.soc.cpu.stream.cancel_cycle || board.soc.cpu.stream.redirect_lookup;
    integer resident_redirect_hits = 0, resident_redirect_misses = 0, history_evictions = 0;
    wire instruction_stall = !board.soc.cpu.execute_valid && !board.soc.cpu.fetch_accept &&
        !redirect_busy;
    integer stream_full = 0, stream_highwater = 0, window_full = 0, constant_wait = 0;
    integer redirect_clock = 0, redirect_to_admit_total = 0, redirect_to_admit_max = 0;
    integer redirects_admitted = 0;
    reg redirect_waiting = 0;

    initial begin
        if (!$value$plusargs("image=%s", image) || !$value$plusargs("words=%d", words) ||
            !$value$plusargs("start_pc=%d", start_pc) || !$value$plusargs("end_pc=%d", end_pc) ||
            !$value$plusargs("list_word=%d", list_word) || !$value$plusargs("matrix_word=%d", matrix_word) ||
            !$value$plusargs("state_word=%d", state_word) || !$value$plusargs("result_word=%d", result_word) ||
            words < 1 || words > WORDS)
            $fatal(1, "missing CoreMark image or labels");
        $readmemh(image, board.soc.bram.words, 0, words - 1);
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
            if (board.soc.bram.take_instruction)
                instruction_reads = instruction_reads + 1;
            if (board.soc.bram.i_valid && !board.soc.bram.i_ready)
                instruction_port_wait = instruction_port_wait + 1;
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
            else if (redirect_busy)
                redirect_stalls = redirect_stalls + 1;
            else
                instruction_stalls = instruction_stalls + 1;
            if (board.soc.cpu.stream_count == board.soc.cpu.stream.WORDS)
                stream_full = stream_full + 1;
            if (board.soc.cpu.stream.full)
                window_full = window_full + 1;
            if (board.soc.cpu.stream_count > stream_highwater)
                stream_highwater = board.soc.cpu.stream_count;
            if (board.soc.cpu.pending_constant)
                constant_wait = constant_wait + 1;
            if (board.soc.cpu.stream.redirect_hit)
                resident_redirect_hits = resident_redirect_hits + 1;
            if (board.soc.cpu.stream.restart)
                resident_redirect_misses = resident_redirect_misses + 1;
            if (board.soc.cpu.stream.evict)
                history_evictions = history_evictions + 1;
            if (board.soc.cpu.redirect) begin
                redirects = redirects + 1;
                redirect_clock = clocks;
                redirect_waiting = 1;
            end else if (redirect_waiting && board.soc.cpu.fetch_accept) begin
                redirect_waiting = 0;
                redirects_admitted = redirects_admitted + 1;
                redirect_to_admit_total = redirect_to_admit_total + clocks - redirect_clock;
                if (clocks - redirect_clock > redirect_to_admit_max)
                    redirect_to_admit_max = clocks - redirect_clock;
            end
            if (board.soc.bram.take_data) begin
                if (board.soc.d_write)
                    data_writes = data_writes + 1;
                else
                    data_reads = data_reads + 1;
            end
            if (!board.soc.cpu.execute_valid) begin
                fetch_clocks = fetch_clocks + 1;
                if (!board.soc.cpu.stream_valid[0])
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
            if (const_stalls > constant_wait || const_stall_events > const_stalls ||
                instruction_stall_events > instruction_stalls)
                $fatal(1, "invalid instruction stall accounting");
            $display("PROFILE clocks=%0d cache_enabled=0 bram_ports=%0d", end_clock - start_clock, board.soc.bram.PORTS);
            $display("PROFILE const_stall=%0d instruction_stall=%0d redirect_stall=%0d execute_wait=%0d decode_bubble=%0d",
                     const_stalls, instruction_stalls, redirect_stalls, execute_waits, decode_bubbles);
            $display("PROFILE const_fifo_empty=%0d const_stall_events=%0d instruction_stall_events=%0d",
                     const_fifo_empty, const_stall_events, instruction_stall_events);
            $display("PROFILE empty_execute=%0d retired=%0d waiting=%0d",
                     fetch_clocks, retire_clocks, waiting_clocks);
            $display("PROFILE fetch_unready=%0d fetch_ready=%0d redirects=%0d", unready_clocks, ready_clocks, redirects);
            $display("PROFILE bram_instruction_reads=%0d bram_data_reads=%0d bram_data_writes=%0d bram_instruction_port_wait=%0d",
                     instruction_reads, data_reads, data_writes, instruction_port_wait);
            $display("PROFILE stream_full=%0d stream_highwater=%0d constant_wait=%0d",
                     stream_full, stream_highwater, constant_wait);
            $display("PROFILE stream_words=%0d ahead_words=%0d resident_redirect_hits=%0d resident_redirect_misses=%0d history_evictions=%0d",
                     board.soc.cpu.stream.WORDS, board.soc.cpu.stream.AHEAD_WORDS,
                     resident_redirect_hits, resident_redirect_misses, history_evictions);
            $display("PROFILE window_full=%0d redirects_admitted=%0d redirect_to_admit_total=%0d redirect_to_admit_max=%0d",
                     window_full, redirects_admitted, redirect_to_admit_total, redirect_to_admit_max);
            $display("COREMARK %0d %0d %h %h %h %h", end_clock - start_clock, clocks,
                     board.soc.bram.words[list_word], board.soc.bram.words[matrix_word], board.soc.bram.words[state_word], board.soc.bram.words[result_word]);
            $finish;
        end
        if (clocks == 500000000)
            $fatal(1, "CoreMark timed out at PC %h", board.soc.cpu.pc);
        clocks = clocks + 1;
    end
endmodule
