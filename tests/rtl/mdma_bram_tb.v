`timescale 1ns/1ps

module mdma_bram_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    reg i_valid = 0, d_valid = 0, d_write = 0;
    reg [14:0] i_addr = 0, d_addr = 0;
    reg [63:0] d_data = 0;
    reg [7:0] d_mask = 0;
    wire i_ready, i_reply, d_ready, d_reply;
    wire [63:0] i_data, d_result;

    mdma_bram dut (
        .clk(clk), .reset(reset), .i_valid(i_valid), .i_addr(i_addr),
        .i_ready(i_ready), .i_reply(i_reply), .i_data(i_data),
        .d_valid(d_valid), .d_write(d_write), .d_addr(d_addr), .d_data(d_data),
        .d_mask(d_mask), .d_ready(d_ready), .d_reply(d_reply), .d_result(d_result)
    );

    task check_cycle(input i_expected, d_expected);
        begin
            @(posedge clk);
            if ((i_valid && i_ready) !== i_expected || (d_valid && d_ready) !== d_expected)
                $fatal(1, "unexpected BRAM acceptance");
            @(negedge clk);
            if (i_reply !== i_expected || d_reply !== d_expected)
                $fatal(1, "BRAM reply did not follow acceptance after one clock");
        end
    endtask

    initial begin
        dut.words[0] = 64'h0123456789abcdef;
        dut.words[32767] = 64'hffeeddccbbaa9988;
        check_cycle(0, 0);

        reset = 0;
        i_valid = 1;
        d_valid = 1;
        d_addr = 32767;
        check_cycle(dut.PORTS == 2, 1);
        if ((dut.PORTS == 2 && i_data !== 64'h0123456789abcdef) ||
            d_result !== 64'hffeeddccbbaa9988)
            $fatal(1, "simultaneous BRAM reads");

        d_write = 1;
        d_mask = 8'hff;
        d_data = 64'hfedcba9876543210;
        check_cycle(dut.PORTS == 2, 1);
        if (dut.PORTS == 2 && i_data !== 64'h0123456789abcdef)
            $fatal(1, "independent instruction read during data write");

        i_addr = 32767;
        d_mask = 8'h55;
        d_data = 64'h0011223344556677;
        check_cycle(0, 1);
        d_mask = 0;
        check_cycle(dut.PORTS == 2, 1);
        if (dut.PORTS == 2 && i_data !== 64'hfe11ba3376553277)
            $fatal(1, "zero-mask write interfered with instruction read");

        d_valid = 0;
        check_cycle(1, 0);
        if (i_data !== 64'hfe11ba3376553277)
            $fatal(1, "masked write did not preserve untouched lanes");

        reset = 1;
        check_cycle(0, 0);
        reset = 0;
        i_valid = 0;
        d_valid = 1;
        d_write = 0;
        check_cycle(0, 1);
        if (d_result !== 64'hfe11ba3376553277)
            $fatal(1, "reset changed BRAM contents");
        $display("PASS %0d-port BRAM response, arbitration, and byte masks", dut.PORTS);
        $finish;
    end
endmodule
