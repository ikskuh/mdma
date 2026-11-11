`timescale 1ns/1ps

module mdma_compare_riscv_tb;
    reg clk = 0, reset = 1;
    always #5 clk = !clk;
    wire halted;
    wire [3:0] fault;
    mdma_compare_top dut (
        .clk(clk), .reset(reset), .serial_rx(1'b1),
        .serial_tx(), .halted(halted), .fault(fault)
    );

    string image;
    integer clocks = 0, start_clock = -1, end_clock = -1;
    integer i_reads = 0, d_reads = 0, d_writes = 0, i_wait = 0;
    integer timed_i, timed_dr, timed_dw, timed_wait;
    wire expect_timing = $test$plusargs("timed");

    initial begin
        if (!$value$plusargs("image=%s", image))
            $fatal(1, "missing +image");
        $readmemh(image, dut.board.soc.bram.words);
        repeat (3) @(negedge clk);
        reset = 0;
    end

    always @(posedge clk) if (!reset) begin
        if (halted) begin
            if (fault != 0)
                $fatal(1, "CPU fault %d after %d clocks", fault, clocks);
            if (expect_timing && (start_clock < 0 || end_clock <= start_clock))
                $fatal(1, "missing CoreMark timing interval");
            if (start_clock < 0) begin
                timed_i = i_reads;
                timed_dr = d_reads;
                timed_dw = d_writes;
                timed_wait = i_wait;
            end
            $display("BENCH %0d %0d %08x %0d %0d %0d %0d",
                     start_clock < 0 ? clocks : end_clock - start_clock,
                     clocks, dut.board.soc.cpu.exit_code, timed_i, timed_dr, timed_dw, timed_wait);
            $finish;
        end
        if (clocks == 100000000)
            $fatal(1, "cycle limit");
        if (dut.board.soc.cpu.bench_start) begin
            if (start_clock >= 0)
                $fatal(1, "duplicate CoreMark start");
            start_clock = clocks;
            i_reads = 0;
            d_reads = 0;
            d_writes = 0;
            i_wait = 0;
        end
        if (dut.board.soc.cpu.bench_end) begin
            if (start_clock < 0 || end_clock >= 0)
                $fatal(1, "unexpected CoreMark end");
            end_clock = clocks;
            timed_i = i_reads;
            timed_dr = d_reads;
            timed_dw = d_writes;
            timed_wait = i_wait;
        end
        clocks = clocks + 1;
        if (dut.board.soc.bram.take_instruction) i_reads = i_reads + 1;
        if (dut.board.soc.bram.i_valid && !dut.board.soc.bram.i_ready) i_wait = i_wait + 1;
        if (dut.board.soc.bram.take_data) begin
            if (dut.board.soc.bram.d_write) d_writes = d_writes + 1;
            else d_reads = d_reads + 1;
        end
    end
endmodule
