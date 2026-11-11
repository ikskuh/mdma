module mdma_alu_tb;
    localparam SINKS = `SINKS;
    localparam SOURCES = `SOURCES;
    localparam REQUESTS = `REQUESTS;
    localparam REGISTERED = `REGISTERED;
    localparam INPUT_BITS = 1 + 65*SINKS + SOURCES;
    localparam OUTPUT_BITS = SINKS + 65*SOURCES;
    localparam VECTOR_BITS = 64*SINKS + 65*SOURCES;

    reg clk = 0;
    reg [INPUT_BITS-1:0] drive;
    wire [OUTPUT_BITS-1:0] observed;
    reg [VECTOR_BITS-1:0] vectors [0:REQUESTS-1];
    wire [SINKS-1:0] operands_take = observed[SINKS-1:0];
    wire [SOURCES-1:0] outputs_valid;

    mdma_alu_dut dut (.clk(clk), .drive(drive), .observed(observed));

    for (genvar lane = 0; lane < SOURCES; lane = lane + 1) begin : source_valid
        assign outputs_valid[lane] = observed[SINKS+65*lane+64];
    end

    task tick;
        begin
            #1 clk = 1;
            #1 clk = 0;
            #1;
        end
    endtask

    task drive_request;
        input integer request;
        input [SINKS-1:0] valid;
        input [SOURCES-1:0] take;
        begin
            drive = 0;
            for (integer lane = 0; lane < SINKS; lane = lane + 1) begin
                drive[1+65*lane +: 64] = vectors[request][64*lane +: 64];
                drive[65+65*lane] = valid[lane];
            end
            drive[1+65*SINKS +: SOURCES] = take;
            #1;
        end
    endtask

    task check_result;
        input integer request;
        reg expected_valid;
        reg [63:0] expected_data;
        begin
            if (request >= REQUESTS)
                $fatal(1, "unexpected extra result");
            for (integer lane = 0; lane < SOURCES; lane = lane + 1) begin
                expected_valid = vectors[request][64*SINKS+65*lane+64];
                expected_data = vectors[request][64*SINKS+65*lane +: 64];
                if (outputs_valid[lane] !== expected_valid)
                    $fatal(1, "request %0d, lane %0d: valid %b, expected %b",
                           request, lane, outputs_valid[lane], expected_valid);
                if (expected_valid && observed[SINKS+65*lane +: 64] !== expected_data)
                    $fatal(1, "request %0d, lane %0d: data %h, expected %h",
                           request, lane, observed[SINKS+65*lane +: 64], expected_data);
            end
        end
    endtask

    task reset_fu;
        begin
            drive[0] = 1;
            #1;
            if (outputs_valid !== 0 || operands_take !== 0)
                $fatal(1, "reset did not suppress transfers");
            tick;
            drive = 0;
            #1;
            if (outputs_valid !== 0)
                $fatal(1, "reset left a valid result");
        end
    endtask

    task cancel_stalled_result;
        integer elapsed;
        reg took_operands;
        begin
            drive_request(0, '1, '0);
            elapsed = 0;
            while (outputs_valid === 0 && elapsed < 50) begin
                took_operands = operands_take === '1;
                tick;
                if (took_operands)
                    drive_request(0, '0, '0);
                elapsed = elapsed + 1;
            end
            if (!(|outputs_valid))
                $fatal(1, "expected a result to cancel");
            reset_fu;
        end
    endtask

    task check_timing;
        begin
            drive_request(0, '1, '1);
            if (operands_take !== '1)
                $fatal(1, "first complete operand group was not accepted");
            if (REGISTERED) begin
                if (outputs_valid !== 0)
                    $fatal(1, "registered result appeared before the first edge");
            end else begin
                check_result(0);
            end
            tick;
            drive_request(1, '1, '1);
            if (operands_take !== '1)
                $fatal(1, "second group was not accepted on the next clock");
            check_result(REGISTERED ? 0 : 1);
            tick;
            drive_request(0, '0, '1);
            if (REGISTERED)
                check_result(1);
            else if (outputs_valid !== 0)
                $fatal(1, "passthrough mode retained an accepted result");
            tick;
            if (outputs_valid !== 0)
                $fatal(1, "result stage did not drain");
        end
    endtask

    integer seed = 42;
    integer sent = 0;
    integer received = 0;
    integer stalls = 0;
    integer cycles = 0;
    reg [SINKS-1:0] input_valid = 0;
    reg [SOURCES-1:0] take;
    reg stalled = 0;
    reg accepted;

    initial begin
        $readmemh("vectors.hex", vectors);
        drive = 0;
        reset_fu;

        cancel_stalled_result;

        if ($test$plusargs("timing")) begin
            check_timing;
            $finish;
        end

        seed = $urandom(seed);
        while (received < REQUESTS && cycles < 50*REQUESTS) begin
            if (sent < REQUESTS)
                for (integer lane = 0; lane < SINKS; lane = lane + 1)
                    if (cycles % 9 == 8 || $urandom_range(0, 2) == 0)
                        input_valid[lane] = 1;

            // Exercise every sibling and occasionally sample several together.
            if (cycles < 8 || cycles % 17 < 3)
                take = 0;
            else if (cycles % 9 == 8)
                take = '1;
            else
                take = 1 << $urandom_range(0, SOURCES-1);

            drive_request(sent < REQUESTS ? sent : 0, input_valid, take);
            accepted = operands_take === '1;
            if (operands_take !== 0 && (!accepted || input_valid !== '1))
                $fatal(1, "partial operand group was consumed");
            if (stalled && outputs_valid === 0)
                $fatal(1, "stalled result disappeared");

            if (outputs_valid !== 0) begin
                if (received == sent && input_valid !== '1)
                    $fatal(1, "result without a complete operand group");
                check_result(received);
                stalled = !(|(outputs_valid & take));
                if (stalled)
                    stalls = stalls + 1;
                else begin
                    if (received >= sent + accepted)
                        $fatal(1, "result consumed without accepting its operands");
                    received = received + 1;
                end
            end
            tick;
            if (accepted) begin
                sent = sent + 1;
                input_valid = 0;
            end
            cycles = cycles + 1;
        end
        if (received != REQUESTS || sent != REQUESTS || stalls == 0)
            $fatal(1, "incomplete run: sent %0d, received %0d, stalls %0d", sent, received, stalls);

        drive_request(0, '0, '1);
        repeat (3) begin
            if (outputs_valid !== 0 || operands_take !== 0)
                $fatal(1, "extra transfer after drain");
            tick;
        end
        $finish;
    end
endmodule
