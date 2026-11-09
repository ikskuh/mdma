`timescale 1ns/1ps

module mdma_serial_tb;
    localparam CLOCKS_PER_BIT = 16;
    reg clk = 0;
    always #5 clk = !clk;
    reg mem_clk = 0;
    integer mem_half_period = 8;
    initial if ($value$plusargs("mem_half_period=%d", mem_half_period) && mem_half_period <= 0)
        $fatal(1, "memory clock half-period must be positive");
    always #(mem_half_period) mem_clk = !mem_clk;
    reg reset = 1;
    wire serial_in, serial_out, halted;
    wire [3:0] fault;
    wire [31:0] sram_address;
    wire [63:0] sram_data;
    wire cs_n, oe_n, we_n;
    reg [63:0] memory [0:255];
    reg [4095:0] image_path;
    integer words, cell_word, readback_word, clocks;
    integer bus_clocks = 0;
    integer request_clocks = 0;
    reg [3:0] seen_access = 0;
    reg [3:0] seen_round_trip = 0;
    wire [1:0] access_kind = !board.we ? 0 : board.sel == 8'hff ? 1 : board.sel != 0 ? 2 : 3;
    wire [1:0] request_kind = !board.soc.d_we ? 0 : board.soc.d_sel == 8'hff ? 1 :
                              board.soc.d_sel != 0 ? 2 : 3;

    mdma_ecp5 #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) board (
        .math_clk({4{clk}}), .clk(clk), .mem_clk(mem_clk), .reset(reset), .serial_rx(serial_in), .serial_tx(serial_out),
        .halted(halted), .fault(fault),
        .sram_a(sram_address), .sram_d(sram_data), .sram_cs_n(cs_n), .sram_oe_n(oe_n), .sram_we_n(we_n)
    );

    assign sram_data = !cs_n && !oe_n && we_n ? memory[sram_address[7:0]] : 64'bz;
    always @(negedge mem_clk) begin
        if (!cs_n && !we_n)
            memory[sram_address[7:0]] <= sram_data;
    end

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
        if (!$value$plusargs("image=%s", image_path) || !$value$plusargs("words=%d", words) ||
            !$value$plusargs("cell=%d", cell_word) || !$value$plusargs("readback=%d", readback_word) ||
            words < 1 || words > 256)
            $fatal(1, "expected +image= +words= +cell= +readback=");
        $readmemh(image_path, memory, 0, words - 1);
        repeat (2) @(negedge clk);
        reset = 0;
        clocks = 0;
        echo(8'ha5);
        echo(8'h00);
        while (!halted) @(negedge clk);
        if (memory[cell_word] !== 64'h123456789abcde99)
            $fatal(1, "SRAM masked store got %h", memory[cell_word]);
        if (memory[readback_word] !== memory[cell_word])
            $fatal(1, "SRAM data readback got %h", memory[readback_word]);
        $display("PASS UART echo and external SRAM read-modify-write (%0d clocks)", clocks);
        $finish;
    end

    always @(posedge clk)
        if (!reset) begin
            clocks <= clocks + 1;
            if (!board.soc.data.request)
                request_clocks <= 0;
            else if (board.soc.d_sram_ack) begin
                if (!seen_round_trip[request_kind]) begin
                    $display("SRAM round trip %0d took %0d CPU clocks", request_kind, request_clocks + 1);
                    seen_round_trip[request_kind] <= 1;
                end
                request_clocks <= 0;
            end else
                request_clocks <= request_clocks + 1;
            if (fault != 0)
                $fatal(1, "CPU fault %d", fault);
            if (clocks >= 15000)
                $fatal(1, "UART/SRAM test timed out");
        end
    always @(posedge mem_clk)
        if (!reset) begin
            if (!board.cyc || !board.stb)
                bus_clocks <= 0;
            else if (board.ack) begin
                if (!seen_access[access_kind]) begin
                    $display("SRAM access %0d took %0d memory clocks", access_kind, bus_clocks + 1);
                    seen_access[access_kind] <= 1;
                end
                bus_clocks <= 0;
            end else
                bus_clocks <= bus_clocks + 1;
        end
endmodule
