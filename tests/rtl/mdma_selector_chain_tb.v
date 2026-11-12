module mdma_selector_chain_tb #(
    parameter CHAIN = 0, SINK_MODE = 0, SOURCE_MODE = 0, REGISTERED = 1, BYPASS = 1
);
    localparam ACTIVE = CHAIN == 1 ? 1 : 3;
    localparam REQUESTS = 160;
    reg clk = 0, reset = 0;
    reg [63:0] data = 0;
    reg valid = 0, take = 0;
    reg [5:0] sink_address = 0, source_address = 0;
    reg [62:0] other_ready = 0;
    reg [64*(64-ACTIVE)-1:0] other_data = 0;
    reg [63-ACTIVE:0] other_valid = 0;
    wire [4095:0] sink_data;
    wire [63:0] sink_valid, source_take;
    wire input_take, output_valid;
    wire [63:0] output_data;

    mdma_selector_chain_fixture #(
        .CHAIN(CHAIN), .SINK_MODE(SINK_MODE), .SOURCE_MODE(SOURCE_MODE),
        .REGISTERED(REGISTERED), .BYPASS(BYPASS)
    ) dut (
        .clk(clk), .reset(reset), .i_data(data), .i_valid(valid),
        .i_sink_address(sink_address), .i_source_address(source_address), .i_take(take),
        .i_other_sink_ready(other_ready), .i_other_source_data(other_data),
        .i_other_source_valid(other_valid), .o_sink_data(sink_data), .o_sink_valid(sink_valid),
        .o_input_take(input_take), .o_data(output_data), .o_valid(output_valid),
        .o_source_take(source_take)
    );

    function [63:0] payload(input integer index);
        payload = (64'hfedcba9876543211 + index) * 64'h9e3779b97f4a7c15;
    endfunction

    function [63:0] expected(input [63:0] word, input integer source);
        if (CHAIN == 1)
            expected = word;
        else
            case (source)
                0: expected = -word;
                1: expected = ~word;
                2: for (integer byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                    expected[8*byte_index +: 8] = word[8*(7-byte_index) +: 8];
            endcase
    endfunction

    task tick;
        begin
            #1 clk = 1;
            #1 clk = 0;
            #1;
        end
    endtask

    task clear;
        begin
            reset = 1;
            #1;
            if (input_take !== 0 || output_valid !== 0 || sink_valid !== 0 || source_take !== 0)
                $fatal(1, "reset allowed a transfer");
            tick;
            valid = 0;
            take = 0;
            sink_address = 0;
            source_address = 0;
            reset = 0;
            repeat (8) begin
                #1;
                if (output_valid !== 0)
                    $fatal(1, "stale result after reset");
                tick;
            end
        end
    endtask

    task check_endpoints;
        begin
            valid = 1;
            take = 1;
            for (integer lane = ACTIVE; lane < 64; lane = lane + 1) begin
                other_data[64*(lane-ACTIVE) +: 64] = payload(lane);
                other_valid[lane-ACTIVE] = lane[0];
            end
            for (integer lane = 1; lane < 64; lane = lane + 1) begin
                data = payload(lane+128);
                sink_address = lane[5:0];
                source_address = 6'd63;
                other_ready = 0;
                #1;
                if (sink_valid !== (64'b1 << lane) || input_take !== 0)
                    $fatal(1, "wrong sink decode or readiness for %0d", lane);
                other_ready[lane-1] = 1;
                #1;
                if (input_take !== 1 || sink_data[64*lane +: 64] !== data)
                    $fatal(1, "wrong sink word or take for %0d", lane);
                if (SINK_MODE == 1 && sink_data[63:0] !== 0)
                    $fatal(1, "unselected active sink was not zero");
                tick;
            end
            valid = 0;
            for (integer lane = ACTIVE; lane < 64; lane = lane + 1) begin
                source_address = lane[5:0];
                #1;
                if (output_data !== payload(lane) || output_valid !== lane[0] ||
                    source_take !== (lane[0] ? 64'b1 << lane : 64'b0))
                    $fatal(1, "wrong background source word or handshake at %0d", lane);
            end
            source_address = 0;
            #1;
            if (output_valid !== 0)
                $fatal(1, "background sink writes reached the active path");
        end
    endtask

    task check_isolation;
        begin
            data = payload(0);
            valid = 1;
            take = 1;
            source_address = 63;
            repeat (16) begin
                #1;
                if (source_take !== (64'b1 << 63))
                    $fatal(1, "background take leaked to the active path");
                if (input_take) begin
                    tick;
                    valid = 0;
                end else begin
                    tick;
                end
            end
            source_address = 0;
            #1;
            if (output_valid !== 1 || output_data !== expected(payload(0), 0))
                $fatal(1, "background take retired the active result");
            tick;
            valid = 0;
            #1;
            if (output_valid !== 0)
                $fatal(1, "active result was not retired exactly once");
        end
    endtask

    task check_full;
        integer sent;
        begin
            if (CHAIN != 0) begin
                valid = 1;
                take = 0;
                sink_address = 0;
                source_address = 0;
                sent = 0;
                for (integer cycle = 0; cycle < 32; cycle = cycle + 1) begin
                    data = payload(sent);
                    #1;
                    if (input_take)
                        sent = sent + 1;
                    tick;
                end
                if (sent == 0 || input_take !== 0 || output_valid !== 1 ||
                    output_data !== expected(payload(0), 0))
                    $fatal(1, "stalled chain did not fill or lost its head");
                if (sent != (CHAIN == 1 ? 4 : 8 + REGISTERED))
                    $fatal(1, "stalled chain accepted %0d entries", sent);
                take = 1;
                #1;
                if (input_take !== (BYPASS != 0) || source_take !== 1)
                    $fatal(1, "full FIFO replacement did not follow BYPASS");
                tick;
            end
        end
    endtask

    integer seed = 42;
    task run_active;
        input stream;
        integer sent, received, selected;
        reg pushed, popped, started, held;
        begin
            sent = 0;
            received = 0;
            started = 0;
            held = 0;
            sink_address = 0;
            for (integer cycle = 0; received < REQUESTS && cycle < 32*REQUESTS; cycle = cycle + 1) begin
                if (!valid && sent < REQUESTS)
                    valid = stream || cycle % 9 == 8 || $urandom_range(0, 2) != 0;
                data = payload(sent);
                selected = received % ACTIVE;
                source_address = selected[5:0];
                take = stream || (cycle >= 20 && (cycle % 11 == 10 || $urandom_range(0, 2) != 0));
                #1;
                pushed = input_take;
                popped = output_valid && take;
                if (sink_valid !== (valid ? 64'b1 : 64'b0))
                    $fatal(1, "active sink valid mismatch");
                if (stream && (pushed !== valid || (started && output_valid !== 1)))
                    $fatal(1, "continuous stream stalled at %0d", cycle);
                if (held && output_valid !== 1)
                    $fatal(1, "stalled result lost validity");
                if (source_take !== (popped ? 64'b1 << selected : 64'b0))
                    $fatal(1, "only the addressed valid sibling may be taken");
                if (output_valid && output_data !== expected(payload(received), selected))
                    $fatal(1, "wrong result %0d for source %0d", received, selected);
                held = output_valid && !take;
                if (popped) begin
                    if (received >= sent + pushed)
                        $fatal(1, "result retired before its operand");
                    received = received + 1;
                    started = 1;
                end
                tick;
                if (pushed) begin
                    sent = sent + 1;
                    valid = 0;
                end
            end
            if (received != REQUESTS || sent != REQUESTS)
                $fatal(1, "sent %0d and received %0d words", sent, received);
            valid = 0;
            take = 1;
            #1;
            if (output_valid !== 0 || input_take !== 0)
                $fatal(1, "extra transfer after draining");
        end
    endtask

    initial begin
        seed = $urandom(seed);
        clear;
        check_endpoints;
        clear;
        check_isolation;
        clear;
        check_full;
        clear;
        run_active(0);
        clear;
        run_active(1);
        $finish;
    end
endmodule
