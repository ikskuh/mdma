`timescale 1ns/1ps

module mdma_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    reg [63:0] memory [0:16383];
    integer words, cycles, lane, max_clocks;
    reg [4095:0] image_path, dump_path;

    wire i_cyc, i_stb, d_cyc, d_stb, d_we;
    wire [63:0] i_addr, d_addr, d_out;
    wire [7:0] d_sel;
    wire halted;
    wire [3:0] fault;
    wire [31:0] ticks;
    wire i_in_bounds = i_addr[63:3] < words;
    wire d_in_bounds = d_addr[63:3] < words;
    integer mem_started = -1;

    reg [3:0] math_clk = 0;
    always #7  math_clk[0] = !math_clk[0];
    always #9  math_clk[1] = !math_clk[1];
    always #11 math_clk[2] = !math_clk[2];
    always #13 math_clk[3] = !math_clk[3];
    mdma_cpu dut (
        .math_clk(math_clk),
        .clk(clk), .reset(reset),
        .i_wb_cyc(i_cyc), .i_wb_stb(i_stb), .i_wb_adr(i_addr),
        .i_wb_dat(memory[i_addr[16:3]]), .i_wb_ack(i_cyc && i_stb && i_in_bounds),
        .i_wb_err(i_cyc && i_stb && !i_in_bounds), .i_wb_stall(1'b0),
        .d_wb_cyc(d_cyc), .d_wb_stb(d_stb), .d_wb_we(d_we), .d_wb_sel(d_sel),
        .d_wb_adr(d_addr), .d_wb_dat_o(d_out), .d_wb_dat_i(memory[d_addr[16:3]]),
        .d_wb_ack(d_cyc && d_stb && d_in_bounds), .d_wb_err(d_cyc && d_stb && !d_in_bounds),
        .halted(halted), .fault(fault), .ticks(ticks)
    );

    always @(posedge clk) begin
        if (!reset && $test$plusargs("trace"))
            $display("TRACE clock=%0d pc=%#h", cycles, dut.pc);
        if (d_cyc && d_stb && d_in_bounds && d_we)
            for (lane = 0; lane < 8; lane = lane + 1)
                if (d_sel[lane])
                    memory[d_addr[16:3]][lane*8 +: 8] <= d_out[lane*8 +: 8];
    end

    genvar fu;
    generate
        for (fu = 0; fu < 27; fu = fu + 1) begin: observe_unit
            if (fu >= 7 && fu <= 10) begin: math
                integer clock_count = 0, started;
                always @(posedge math_clk[fu-7]) if (!reset) begin
                    if (dut.unit[fu].implemented.clocked_math.engine.take)
                        started = clock_count;
                    if (dut.unit[fu].implemented.clocked_math.engine.done)
                        $display("LATENCY %0d %0d", fu, clock_count - started + 1);
                    clock_count = clock_count + 1;
                end
            end else if (fu < 21 && fu != 17) begin: pipeline
                integer start_clock [0:15];
                reg [3:0] tail = 0, head = 0;
                always @(posedge clk) if (!reset) begin
                    if (dut.take[fu]) begin
                        start_clock[tail] <= cycles;
                        tail <= tail + 1'b1;
                    end
                    if (dut.publish[fu]) begin
                        $display("LATENCY %0d %0d", fu,
                                 dut.take[fu] && head == tail ? 1 : cycles - start_clock[head] + 1);
                        head <= head + 1'b1;
                    end
                end
            end
        end
    endgenerate
    wire [1:0] next_mem_request = dut.unit[17].implemented.local_clock.memory.mem.next_request;
    reg [1:0] mem_kind;
    always @(posedge clk) if (!reset) begin
        if (dut.unit[17].implemented.local_clock.memory.mem.start) begin
            mem_started = cycles;
            mem_kind = next_mem_request;
        end
        if (dut.publish[17] || (d_cyc && d_we && d_in_bounds && mem_kind == 1))
            $display("LATENCY %0d %0d", 27 + mem_kind, cycles - mem_started + 1);
    end

    reg [63:0] first_pc, second_pc;
    integer first_dispatch = -3, second_dispatch = -3, last_arith = -2;
    integer arith_writes = 0, arith_reads = 0;
    integer arith_start [0:15];
    integer consecutive_moves = 0, consecutive_arith = 0, parallel_units = 0;
    integer arith_min = 250000, arith_max = 0, latency;
    integer first_storage_push = -1, stash_visible = -1, stack_visible = -1;
    always @(posedge clk) if (!reset && $test$plusargs("five_wide")) begin
        if (first_storage_push < 0 && dut.dispatch_push[46] && dut.dispatch_push[50])
            first_storage_push = cycles;
        if (first_storage_push >= 0 && stash_visible < 0 && dut.source_ready[43])
            stash_visible = cycles - first_storage_push;
        if (first_storage_push >= 0 && stack_visible < 0 && dut.source_ready[47])
            stack_visible = cycles - first_storage_push;
        if (dut.pc == first_pc && dut.execute_valid && dut.commits == 5'b11111 &&
            $countones(dut.result_pop) == 5 && $countones(dut.dispatch_push) == 5)
            first_dispatch = cycles;
        if (dut.pc == second_pc && dut.execute_valid && dut.commits == 5'b11111 &&
            $countones(dut.result_pop) == 5 && $countones(dut.dispatch_push) == 5 &&
            $countones(dut.input_push) == 5 && cycles == first_dispatch + 1)
            second_dispatch = cycles;
        if (cycles == second_dispatch + 1 && $countones(dut.input_push) == 5)
            consecutive_moves = consecutive_moves + 1;
        if (dut.take[0]) begin
            arith_start[arith_writes] = cycles;
            arith_writes = arith_writes + 1;
            if (cycles == last_arith + 1)
                consecutive_arith = consecutive_arith + 1;
            last_arith = cycles;
        end
        if (dut.publish[0]) begin
            latency = cycles - arith_start[arith_reads] + 1;
            if (latency < arith_min) arith_min = latency;
            if (latency > arith_max) arith_max = latency;
            arith_reads = arith_reads + 1;
        end
        if (dut.take[0] && (dut.take[2] || dut.take[3]))
            parallel_units = parallel_units + 1;
        if (arith_reads >= 4 || fault != 0) begin
            $display("BENCH cached consecutive five-transfer pairs: %0d", consecutive_moves);
            $display("BENCH consecutive ARITH pops: %0d; concurrent ARITH/LOGIC launches: %0d",
                     consecutive_arith, parallel_units);
            $display("BENCH ARITH latency: %0d..%0d clocks, %0d results", arith_min, arith_max, arith_reads);
            $display("BENCH storage readable after push: STASH %0d, STACK %0d clock edges",
                     stash_visible, stack_visible);
            $finish;
        end
    end

    reg [63:0] alu_producer, alu_consumer;
    integer alu_unit, alu_source, alu_sink;
    integer alu_round = 0, alu_dispatched = -1, alu_ready = -1;
    integer alu_consumed = -1, burst_count = 0, burst_first = -1, burst_last = -1;
    always @(posedge clk) if (!reset && $test$plusargs("alu_latency")) begin
        if (dut.execute_valid && dut.pc == alu_producer && dut.dispatch_push[alu_sink]) begin
            alu_round = alu_round + 1;
            if (alu_round == 3)
                alu_dispatched = cycles;
        end
        if (alu_round == 3 && dut.source_ready[alu_source] && alu_ready < 0)
            alu_ready = cycles;
        if (alu_round == 3 && dut.execute_valid && dut.pc == alu_consumer && dut.result_pop[alu_unit])
            alu_consumed = cycles;
        if (alu_consumed >= 0 && dut.take[alu_unit]) begin
            if (burst_count == 0)
                burst_first = cycles;
            burst_count = burst_count + 1;
            burst_last = cycles;
        end
        if (alu_round == 4) begin
            $display("BENCH FU %0d ready=%0d use=%0d burst=%0d/%0d",
                     alu_unit, alu_ready - alu_dispatched,
                     alu_consumed - alu_dispatched, burst_count, burst_last - burst_first);
            $finish;
        end
    end

    initial begin
        if (!$value$plusargs("image=%s", image_path) || !$value$plusargs("dump=%s", dump_path) ||
            !$value$plusargs("words=%d", words) || words < 1 || words > 16384)
            $fatal(1, "expected +image= +dump= +words=");
        if ($test$plusargs("five_wide")) begin
            if (!$value$plusargs("first_pc=%d", first_pc) || !$value$plusargs("second_pc=%d", second_pc))
                $fatal(1, "throughput benchmark needs both dispatch addresses");
        end
        if ($test$plusargs("alu_latency")) begin
            if (!$value$plusargs("alu_producer=%d", alu_producer) ||
                !$value$plusargs("alu_consumer=%d", alu_consumer) ||
                !$value$plusargs("alu_unit=%d", alu_unit) ||
                !$value$plusargs("alu_source=%d", alu_source) ||
                !$value$plusargs("alu_sink=%d", alu_sink))
                $fatal(1, "ALU benchmark needs addresses and port indices");
        end
        if (!$value$plusargs("max_clocks=%d", max_clocks))
            max_clocks = 250000;
        $readmemh(image_path, memory, 0, words - 1);
        repeat (2) @(negedge clk);
        reset = 0;
        cycles = 0;
        while (!halted && fault == 0 && cycles < max_clocks) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (!halted && fault == 0)
            $fatal(1, "hardware timeout after %0d clocks (PC=%h)", cycles, dut.pc);
        $writememh(dump_path, memory, 0, words - 1);
        $display("RESULT %0d %0d %0d", fault, ticks, cycles);
        $finish;
    end
endmodule
