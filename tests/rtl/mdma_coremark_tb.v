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
        if (halted) begin
            if (start_clock < 0 || end_clock <= start_clock)
                $fatal(1, "CoreMark timing boundaries were not reached");
            $display("COREMARK %0d %0d %h %h %h %h", end_clock - start_clock, clocks,
                     memory[list_word], memory[matrix_word], memory[state_word], memory[result_word]);
            $finish;
        end
        if (clocks == 500000000)
            $fatal(1, "CoreMark timed out at PC %h", board.soc.cpu.pc);
        clocks = clocks + 1;
    end
endmodule
