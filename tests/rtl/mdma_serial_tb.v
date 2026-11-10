`timescale 1ns/1ps

module mdma_serial_tb;
    localparam CLOCKS_PER_BIT = 16;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    wire serial_in, serial_out, halted;
    wire [3:0] fault;
    reg [4095:0] image_path;
    integer words, cell_word, readback_word, clocks, expected_fault;
    reg [63:0] first_word;

    mdma_ecp5 #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) board (
        .math_clk({4{clk}}), .clk(clk), .reset(reset), .serial_rx(serial_in), .serial_tx(serial_out),
        .halted(halted), .fault(fault)
    );

    reg [7:0] host_tx_data;
    reg host_tx_valid = 0;
    wire host_tx_ready;
    wire [7:0] host_rx_data;
    wire host_rx_valid;
    reg host_rx_ready = 0;
    mdma_uart #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) host (
        .clk(clk), .reset(reset), .serial_rx(serial_out), .serial_tx(serial_in),
        .rx_data(host_rx_data), .rx_valid(host_rx_valid), .rx_ready(host_rx_ready),
        .tx_data(host_tx_data), .tx_valid(host_tx_valid), .tx_ready(host_tx_ready)
    );

    task echo(input [7:0] expected);
        begin
            while (!host_tx_ready) @(negedge clk);
            host_tx_data = expected;
            host_tx_valid = 1;
            @(negedge clk);
            host_tx_valid = 0;
            while (!host_rx_valid) @(negedge clk);
            if (host_rx_data !== expected)
                $fatal(1, "UART echo got %02h, expected %02h", host_rx_data, expected);
            host_rx_ready = 1;
            @(negedge clk);
            host_rx_ready = 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("expect_fault=%d", expected_fault))
            expected_fault = 0;
        if (!$value$plusargs("image=%s", image_path) || !$value$plusargs("words=%d", words) ||
            words < 1 || words > 32768)
            $fatal(1, "expected +image= and +words=");
        $readmemh(image_path, board.soc.bram.words, 0, words - 1);
        first_word = board.soc.bram.words[0];
        repeat (2) @(negedge clk);
        reset = 0;
        clocks = 0;
        if (expected_fault != 0) begin
            while (fault == 0 && !halted) @(negedge clk);
            if (fault !== expected_fault[3:0] || board.soc.bram.words[0] !== first_word)
                $fatal(1, "BRAM bounds check: fault %d, expected %d", fault, expected_fault);
            $display("PASS BRAM bounds fault without address alias");
            $finish;
        end
        if (!$value$plusargs("cell=%d", cell_word) || !$value$plusargs("readback=%d", readback_word))
            $fatal(1, "expected +cell= and +readback=");
        echo(8'ha5);
        echo(8'h00);
        while (!halted) @(negedge clk);
        if (board.soc.bram.words[cell_word] !== 64'h123456789abcde99)
            $fatal(1, "BRAM masked store got %h", board.soc.bram.words[cell_word]);
        if (board.soc.bram.words[readback_word] !== board.soc.bram.words[cell_word])
            $fatal(1, "BRAM data readback got %h", board.soc.bram.words[readback_word]);
        $display("PASS UART echo and BRAM masked writes (%0d clocks)", clocks);
        $finish;
    end

    always @(posedge clk)
        if (!reset) begin
            clocks <= clocks + 1;
            if (fault != 0 && expected_fault == 0)
                $fatal(1, "CPU fault %d", fault);
            if (clocks >= 15000)
                $fatal(1, "UART/BRAM test timed out");
        end
endmodule
