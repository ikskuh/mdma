module mdma_alu_fifo_tb;
    localparam SINKS = `SINKS;
    localparam SOURCES = `SOURCES;
    localparam REQUESTS = `REQUESTS;
    localparam INPUT_BITS = 1 + 65*SINKS + SOURCES;
    localparam OUTPUT_BITS = SINKS + 65*SOURCES;
    localparam VECTOR_BITS = 64*SINKS + 65*SOURCES;

    reg clk = 0;
    reg [INPUT_BITS-1:0] drive = 0;
    wire [OUTPUT_BITS-1:0] observed;
    reg [VECTOR_BITS-1:0] vectors [0:REQUESTS-1];
    wire [SINKS-1:0] accepted = observed[SINKS-1:0];
    wire [SOURCES-1:0] output_valid;

    mdma_alu_dut dut (.clk(clk), .drive(drive), .observed(observed));

    for (genvar lane = 0; lane < SOURCES; lane = lane + 1) begin : source_valid
        assign output_valid[lane] = observed[SINKS+65*lane+64];
    end

    task tick;
        begin
            #1 clk = 1;
            #1 clk = 0;
            #1;
        end
    endtask

    integer sent [0:SINKS-1];
    integer received = 0;
    reg [SINKS-1:0] pending = 0;
    reg [SINKS-1:0] pushed;
    reg [SOURCES-1:0] take;
    reg stalled = 0;

    task drive_queues;
        begin
            for (integer lane = 0; lane < SINKS; lane = lane + 1) begin
                drive[1+65*lane +: 64] = vectors[sent[lane] < REQUESTS ? sent[lane] : 0][64*lane +: 64];
                drive[65+65*lane] = pending[lane];
            end
            drive[1+65*SINKS +: SOURCES] = take;
            #1;
        end
    endtask

    task advance;
        begin
            pushed = accepted;
            if ((pushed & ~pending) !== 0)
                $fatal(1, "queue took an unavailable operand");
            tick;
            for (integer lane = 0; lane < SINKS; lane = lane + 1) begin
                if (pushed[lane]) begin
                    sent[lane] = sent[lane] + 1;
                    pending[lane] = 0;
                end
            end
        end
    endtask

    task reset_queues;
        begin
            drive = '1;
            #1;
            if (accepted !== 0 || output_valid !== 0)
                $fatal(1, "reset did not suppress transfers");
            tick;
            drive = 0;
            pending = 0;
            for (integer lane = 0; lane < SINKS; lane = lane + 1)
                sent[lane] = 0;
            #1;
            if (output_valid !== 0)
                $fatal(1, "reset left a queued result");
        end
    endtask

    task check_result;
        input integer request;
        reg [64:0] expected;
        begin
            for (integer sink = 0; sink < SINKS; sink = sink + 1)
                if (sent[sink] <= request)
                    $fatal(1, "result %0d appeared before operand %0d was queued", request, sink);
            for (integer lane = 0; lane < SOURCES; lane = lane + 1) begin
                expected = vectors[request][64*SINKS+65*lane +: 65];
                if (output_valid[lane] !== expected[64] ||
                    (expected[64] && observed[SINKS+65*lane +: 64] !== expected[63:0]))
                    $fatal(1, "result %0d lane %0d: got %h expected %h", request, lane,
                           observed[SINKS+65*lane +: 65], expected);
            end
        end
    endtask

    integer seed = 42;
    reg stream, streaming = 0;
    initial begin
        $readmemh("vectors.hex", vectors);
        reset_queues;

        if (SINKS > 1) begin
            // A producer can fill its own four entries while every other
            // producer is idle.
            take = '1;
            repeat (4) begin
                pending = 1;
                drive_queues;
                if (accepted !== 1 || output_valid !== 0)
                    $fatal(1, "operand queue did not accept independently");
                advance;
            end
            pending = 1;
            drive_queues;
            if (accepted !== 0 || output_valid !== 0)
                $fatal(1, "unpaired operand queue exceeded four entries");
            reset_queues;
        end

        // A stalled consumer eventually fills the output FIFO, ALU and input FIFOs.
        take = 0;
        for (integer cycle = 0; cycle < REQUESTS; cycle = cycle + 1) begin
            pending = '1;
            drive_queues;
            advance;
        end
        if (accepted !== 0 || output_valid === 0)
            $fatal(1, "backpressure did not reach every input");
        check_result(0);
        reset_queues;
        repeat (REQUESTS) begin
            if (output_valid !== 0)
                $fatal(1, "reset allowed an old result through");
            tick;
        end

        seed = $urandom(seed);
        stream = $test$plusargs("stream");
        for (integer cycle = 0; received < REQUESTS && cycle < 50*REQUESTS; cycle = cycle + 1) begin
            for (integer lane = 0; lane < SINKS; lane = lane + 1)
                if (sent[lane] < REQUESTS && (stream || cycle % 9 == 8 || $urandom_range(0, 2) == 0))
                    pending[lane] = 1;
            if (stream)
                take = '1;
            else if (cycle < 80 || cycle % 23 < 8)
                take = 0;
            else if (cycle % 9 == 8)
                take = '1;
            else
                take = 1 << $urandom_range(0, SOURCES-1);

            drive_queues;
            if (stream && accepted !== pending)
                $fatal(1, "input stream stalled at cycle %0d", cycle);
            if ((stalled || streaming) && output_valid === 0)
                $fatal(1, "stalled or continuously draining stream lost its head");

            if (output_valid !== 0) begin
                check_result(received);
                stalled = !(|(output_valid & take));
                if (!stalled) begin
                    received = received + 1;
                    streaming = stream;
                end
            end
            advance;
        end

        if (received != REQUESTS)
            $fatal(1, "incomplete run: received %0d of %0d", received, REQUESTS);
        for (integer lane = 0; lane < SINKS; lane = lane + 1)
            if (sent[lane] != REQUESTS)
                $fatal(1, "input %0d sent %0d of %0d operands", lane, sent[lane], REQUESTS);
        take = '1;
        drive_queues;
        repeat (3) begin
            if (output_valid !== 0)
                $fatal(1, "extra result after drain");
            tick;
        end
        $finish;
    end
endmodule
