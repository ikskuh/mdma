module mdma_fifo_write_mux_tb;
    localparam [191:0] DISABLED = {64{3'd5}};
    reg clk = 0;
    reg [319:0] source_data;
    reg [4:0] source_ready;
    reg [191:0] source_id;
    reg [63:0] pull = 0;
    reg [63:0] test_ack = 0;
    wire [4095:0] sink_data;
    wire [63:0] sink_ready, sink_done;
    wire [63:0] sink_ack = test_ack | (pull & sink_ready);
    reg [63:0] captured = 0;
    reg [4095:0] captured_data;

    mdma_fifo_write_mux dut (
        .i_source_data(source_data), .i_source_ready(source_ready),
        .i_source_id(source_id), .i_sink_done(sink_ack),
        .o_sink_data(sink_data), .o_sink_ready(sink_ready), .o_sink_done(sink_done)
    );

    // Model receiving registers. An acknowledgment records an actual pull.
    always @(posedge clk) begin
        for (integer sink = 0; sink < 64; sink = sink + 1) begin
            if (sink_ack[sink]) begin
                if (captured[sink])
                    $fatal(1, "sink %0d captured twice", sink);
                captured[sink] <= 1'b1;
                captured_data[sink*64 +: 64] <= sink_data[sink*64 +: 64];
            end
        end
    end

    task automatic check_outputs;
        reg [2:0] selected;
        begin
            for (integer sink = 0; sink < 64; sink = sink + 1) begin
                selected = source_id[sink*3 +: 3];
                if (selected == 3'd5) begin
                    if ({sink_ready[sink], sink_done[sink]} !== 2'b01)
                        $fatal(1, "disabled sink %0d must be done with ready low", sink);
                end else begin
                    if (sink_ready[sink] !== source_ready[selected] || sink_done[sink] !== sink_ack[sink])
                        $fatal(1, "sink %0d source %0d handshake mismatch", sink, selected);
                    if (source_ready[selected] && sink_data[sink*64 +: 64] !== source_data[selected*64 +: 64])
                        $fatal(1, "sink %0d source %0d data mismatch", sink, selected);
                end
            end
        end
    endtask

    task automatic capture_step(input [63:0] requests, input [63:0] expected_ack, input complete);
        begin
            pull = requests;
            #1;
            check_outputs();
            if (sink_ack !== expected_ack || (&sink_done) !== complete)
                $fatal(1, "unexpected acknowledgment or instruction completion");
            clk = 1;
            #1;
            clk = 0;
            for (integer sink = 0; sink < 64; sink = sink + 1) begin
                if (expected_ack[sink])
                    source_id[sink*3 +: 3] = 3'd5;
            end
            #1;
            check_outputs();
            if (sink_ack !== 64'b0 || (&sink_done) !== complete)
                $fatal(1, "completion changed after retiring acknowledged sinks");
        end
    endtask

    localparam [63:0] MAPPED = (64'b1 << 3) | (64'b1 << 18) | (64'b1 << 33) |
                              (64'b1 << 48) | (64'b1 << 63);

    initial begin
        source_data = {64'hf83e_1029_4bc6_571a, 64'h139d_fce0_8a76_b524, 64'h9807_2145_836a_cdef,
                       64'h8a9f_248c_6b13_5e70, 64'h0123_4567_89ab_cdef};
        source_id = DISABLED;
        source_ready = 5'b11111;
        #1;
        check_outputs();
        if ((&sink_done) !== 1'b1)
            $fatal(1, "all-disabled instruction must be complete");

        // Sweep each selector with source readiness and capture acknowledgment independent.
        for (integer sink = 0; sink < 64; sink = sink + 1) begin
            for (integer selected = 0; selected <= 5; selected = selected + 1) begin
                source_id = DISABLED;
                source_id[sink*3 +: 3] = selected[2:0];
                for (integer state = 0; state < 4; state = state + 1) begin
                    source_ready = 5'b10101;
                    if (selected < 5)
                        source_ready[selected] = state[0];
                    test_ack = 0;
                    test_ack[sink] = state[1];
                    #1;
                    check_outputs();
                end
            end
        end
        test_ack = 0;
        source_ready = 5'b11111;
        for (integer bus = 0; bus < 5; bus = bus + 1)
            source_id[(3+15*bus)*3 +: 3] = bus[2:0];
        capture_step('1, MAPPED, 1'b1);
        if (captured !== MAPPED)
            $fatal(1, "expected exactly five concurrent captures");
        for (integer bus = 0; bus < 5; bus = bus + 1) begin
            if (captured_data[(3+15*bus)*64 +: 64] !== source_data[bus*64 +: 64])
                $fatal(1, "sink captured the wrong concurrent value from bus %0d", bus);
        end

        captured = 0;
        source_data = ~source_data;
        source_ready = 5'b11011;
        for (integer slot = 0; slot < 5; slot = slot + 1)
            source_id[(3+15*slot)*3 +: 3] = 3'd2;
        capture_step('1, 64'b0, 1'b0);
        source_ready[2] = 1'b1;
        for (integer slot = 0; slot < 5; slot = slot + 1) begin
            capture_step(captured | (64'b1 << (3+15*slot)), 64'b1 << (3+15*slot), slot == 4);
            if (captured_data[(3+15*slot)*64 +: 64] !== source_data[2*64 +: 64])
                $fatal(1, "shared source value missing at sink slot %0d", slot);
        end
        if (captured !== MAPPED)
            $fatal(1, "expected five captures from the shared source");
        $display("FIFO write mux checks passed");
        $finish;
    end
endmodule
