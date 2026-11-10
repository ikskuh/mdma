`timescale 1ns/1ps
// Decoder protocol tests use storage only, adding MEM solely when an
// independently blocked FU is needed to preheat or exercise early redirects.
module mdma_decode_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    reg [63:0] memory [0:255], requests [0:127];
    integer rd = 0, wr = 0, queued = 0;
    wire i_cyc = dut.stream.active;
    wire i_stb, d_cyc, halted;
    wire [63:0] i_adr;
    wire [3:0] fault;
    reg hold_literal = 0, hold_data = 0;
    reg [63:0] literal_address = 8, fault_address = -1, data_value = 0;
    wire [63:0] response_address = requests[rd];
    wire response = i_cyc && queued != 0 && !(hold_literal && response_address == literal_address);
    wire response_error = response && response_address == fault_address;
    mdma_cpu dut (
        .clk(clk), .reset(reset), .math_clk({4{clk}}),
        .i_req_valid(i_stb), .i_req_addr(i_adr), .i_req_ready(1'b1),
        .i_rsp_data(memory[response_address[10:3]]), .i_rsp_valid(response), .i_rsp_error(response_error),
        .d_req_valid(d_cyc), .d_req_write(), .d_req_mask(), .d_req_addr(), .d_req_data(),
        .d_req_ready(!hold_data), .d_rsp_data(data_value), .d_rsp_valid(d_cyc && !hold_data), .d_rsp_error(1'b0),
        .halted(halted), .fault(fault), .ticks()
    );
    always @(posedge clk) begin
        if (reset || !i_cyc) begin rd <= 0; wr <= 0; queued <= 0; end
        else begin
            queued <= queued + i_stb - response;
            if (i_stb) begin requests[wr] <= i_adr; wr <= (wr + 1) % 128; end
            if (response) rd <= (rd + 1) % 128;
        end
    end
    function [63:0] one(input [5:0] source, sink, input [1:0] mode);
        reg [63:0] value;
        begin
            value = 0;
            value[5:0] = source;
            value[11:6] = sink;
            value[23:18] = sink < 63 ? 62 - sink : 0;
            value[61:60] = mode;
            one = value;
        end
    endfunction
    function [63:0] two(input [5:0] source0, sink0, source1, sink1, input [1:0] mode);
        reg [63:0] value;
        begin
            value = one(source0, sink0, mode);
            value[17:12] = source1;
            value[23:18] = sink1 - sink0 - 1;
            value[35:30] = sink1 < 63 ? 62 - sink1 : 0;
            two = value;
        end
    endfunction
    task setup;
        integer i;
        begin
            reset = 1;
            hold_literal = 0; hold_data = 0; literal_address = 8;
            fault_address = -1; data_value = 0;
            for (i = 0; i < 256; i = i + 1) memory[i] = one(0, 63, 0);
            repeat (2) @(negedge clk);
        end
    endtask
    task finish_ok;
        begin
            while (!halted && fault == 0) @(negedge clk);
            if (fault != 0) $fatal(1, "unexpected decoder fault %d at %h", fault, dut.pc);
        end
    endtask
    integer scenario = 0, independent = 0, constant_moves = 0, redirect_count = 0;
    integer warm_seen = 0, last_nop = -2, nop_run = 0, clock = 0;
    integer warm_nops;
    reg pc_first = 0, early_redirect = 0;
    always @(posedge clk) if (!reset) begin
        clock = clock + 1;
        if (dut.dispatch_push[46] && !dut.constant_ready) independent = independent + 1;
        if (dut.dispatch_push[47]) constant_moves = constant_moves + 1;
        if (dut.new_jump && !dut.constant_ready) pc_first = 1;
        if (dut.redirect) begin
            redirect_count = redirect_count + 1;
            if (!dut.done) early_redirect = 1;
        end
        if (scenario == 1 && dut.execute_valid && dut.pc == 16) begin
            if (!dut.constant_ready || dut.constant_value !== 64'h123456789abcdef0)
                $fatal(1, "buffered constant acquired artificial latency");
            if (dut.dispatch_push[46] && dut.dispatch_push[47]) warm_seen = 1;
        end
        if (scenario == 1 && dut.done && dut.pc >= 32 && dut.pc < 8*(4 + warm_nops)) begin
            if (clock == last_nop + 1) nop_run = nop_run + 1;
            last_nop = clock;
        end
        if (scenario == 2 && dut.redirect && (!dut.constant_ready && !dut.constant_capture))
            $fatal(1, "redirect destroyed pending constant");
    end
    initial begin
        // Missing constant gates only its own moves.
        setup;
        memory[0] = two(0, 46, 1, 47, 1);
        memory[1] = 64'h123456789abcdef0;
        memory[2] = one(1, 0, 1); memory[3] = -1;
        hold_literal = 1;
        reset = 0;
        while (independent == 0) @(negedge clk);
        repeat (8) @(negedge clk);
        if (constant_moves != 0 || fault != 0) $fatal(1, "constant wait blocked/escaped");
        hold_literal = 0;
        finish_ok;
        if (dut.source_value[44] !== memory[1]) $fatal(1, "delayed constant corrupted");

        // MEM provides a controlled execution stall while raw words preheat.
        scenario = 1;
        setup;
        memory[0] = one(0, 34, 0); memory[1] = one(38, 63, 0);
        memory[2] = two(1, 46, 1, 47, 1); memory[3] = 64'h123456789abcdef0;
        warm_nops = dut.stream.WORDS < 12 ? dut.stream.WORDS - 4 : 8;
        memory[4+warm_nops] = one(1, 0, 1); memory[5+warm_nops] = -1;
        hold_data = 1; reset = 0;
        while (dut.stream.received != dut.stream.WORDS) @(negedge clk);
        hold_data = 0;
        finish_ok;
        if (!warm_seen || nop_run != warm_nops - 1) $fatal(1, "warm instruction/constant throughput");

        // PC commits before the missing constant; redirect on its capture,
        // while the CONST -> STASH_B move still remains to execute.
        scenario = 2;
        setup;
        memory[0] = one(1, 46, 2) | (64'd64 << 48);
        memory[1] = two(43, 0, 1, 47, 1); memory[2] = 64'habcdef;
        memory[8] = one(1, 0, 1); memory[9] = -1;
        literal_address = 16; hold_literal = 1;
        pc_first = 0; early_redirect = 0; redirect_count = 0; reset = 0;
        while (!pc_first) @(negedge clk);
        repeat (8) @(negedge clk);
        if (redirect_count != 0 || fault != 0) $fatal(1, "PC redirected before constant");
        hold_literal = 0;
        finish_ok;
        if (!early_redirect || dut.source_value[44] !== 64'habcdef || redirect_count != 2)
            $fatal(1, "PC-first redirect did not preserve remaining moves");

        // A pending MEM result cannot prevent target prefetch after PC commit.
        scenario = 3;
        setup;
        memory[0] = one(1, 46, 2) | (64'd64 << 48);
        memory[1] = one(0, 34, 0);
        memory[2] = two(43, 0, 38, 47, 0);
        memory[8] = one(1, 0, 1); memory[9] = -1;
        hold_data = 1; data_value = 64'hbeef;
        redirect_count = 0; reset = 0;
        while (redirect_count == 0) @(negedge clk);
        repeat (12) @(negedge clk);
        if (!dut.execute_valid || dut.pc != 16 || dut.fetch_pc != 64 || dut.stream_count == 0)
            $fatal(1, "target prefetch waited for current instruction retirement");
        hold_data = 0;
        finish_ok;
        if (dut.source_value[44] !== 64'hbeef) $fatal(1, "remaining move after redirect lost");

        // Constant precedes the PC value returned through MEM.
        scenario = 4;
        setup;
        memory[0] = one(0, 34, 0);
        memory[1] = two(38, 0, 1, 47, 1); memory[2] = 64'hfedcba;
        memory[8] = one(1, 0, 1); memory[9] = -1;
        hold_data = 1; data_value = 64; redirect_count = 0; reset = 0;
        while (!dut.source_ready[44]) @(negedge clk);
        if (redirect_count != 0 || !dut.constant_ready) $fatal(1, "constant-first redirect");
        hold_data = 0;
        finish_ok;

        // Synchronized moves wait together for CONST.
        scenario = 5;
        setup;
        memory[0] = two(0, 46, 1, 47, 1) | (64'd1 << 62);
        memory[1] = 123; memory[2] = one(1, 0, 1); memory[3] = -1;
        hold_literal = 1; independent = 0; reset = 0;
        while (!dut.execute_valid) @(negedge clk);
        repeat (8) @(negedge clk);
        if (independent != 0 || dut.source_ready[43]) $fatal(1, "sync executed before constant");
        hold_literal = 0;
        finish_ok;

        // A skipped instruction still consumes its extended word exactly once.
        scenario = 6;
        setup;
        memory[0] = one(0, 62, 0);
        memory[1] = one(1, 46, 1) | (64'd1 << 63); memory[2] = 64'hffffffffffffffff;
        memory[3] = one(1, 0, 1); memory[4] = -1;
        literal_address = 16; hold_literal = 1; reset = 0;
        while (!dut.execute_valid || dut.pc != 8) @(negedge clk);
        repeat (8) @(negedge clk);
        hold_literal = 0;
        finish_ok;
        if (dut.source_ready[43]) $fatal(1, "false predicate executed");

        // Required delayed-word error faults, preserving accepted independent moves.
        scenario = 7;
        setup;
        memory[0] = two(0, 46, 1, 47, 1);
        hold_literal = 1; fault_address = 8; independent = 0; reset = 0;
        while (independent == 0) @(negedge clk);
        hold_literal = 0;
        while (fault == 0) @(negedge clk);
        if (fault != 3 || !dut.source_ready[43] || dut.source_ready[44])
            $fatal(1, "required constant fault/partial execution");

        // Speculative fall-through errors disappear on consecutive redirects.
        scenario = 8;
        setup;
        memory[0] = one(1, 0, 2) | (64'd64 << 48);
        memory[8] = one(1, 0, 2) | (64'd128 << 48);
        memory[16] = one(1, 0, 1); memory[17] = -1;
        fault_address = 8; reset = 0;
        finish_ok;
        // An unused extended word is consumed too, even after every move
        // has committed. It cannot become the next decoded instruction.
        scenario = 9;
        setup;
        memory[0] = one(0, 46, 1); memory[1] = 64'hffffffffffffffff;
        memory[2] = one(1, 0, 1); memory[3] = -1;
        hold_literal = 1; independent = 0; reset = 0;
        while (independent == 0) @(negedge clk);
        repeat (6) @(negedge clk);
        if (dut.pc != 0 || !dut.execute_valid || fault != 0)
            $fatal(1, "unused constant lost instruction boundary");
        hold_literal = 0;
        finish_ok;
        $display("PASS decoder immediate readiness, early redirects, throughput, predication, faults");
        $finish;
    end
    initial begin #100000; $fatal(1, "decoder timeout scenario=%d pc=%h fault=%d", scenario, dut.pc, fault); end
endmodule
