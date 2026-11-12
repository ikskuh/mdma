module mdma_sink_selector_tb #(
    parameter integer WIDTH = 64,
    parameter integer SELECT_BITS = 6
);
    localparam integer TARGETS = 2**SELECT_BITS;
    reg [WIDTH-1:0] data;
    reg [SELECT_BITS-1:0] address;
    wire [TARGETS*WIDTH-1:0] output_data [0:2];
    wire [TARGETS-1:0] output_valid [0:2];

    for (genvar mode = 0; mode < 3; mode = mode + 1) begin : implementation
        mdma_sink_selector #(.WIDTH(WIDTH), .SELECT_BITS(SELECT_BITS), .IMPLEMENTATION(mode)) dut (
            .i_data(data), .i_address(address), .o_data(output_data[mode]), .o_valid(output_valid[mode])
        );
    end

    task check;
        input [WIDTH-1:0] payload;
        input integer target;
        reg [TARGETS-1:0] expected_valid;
        reg [WIDTH-1:0] expected_data;
        begin
            data = payload;
            address = target[SELECT_BITS-1:0];
            expected_valid = 0;
            expected_valid[target] = 1'b1;
            #1;
            for (integer mode = 0; mode < 3; mode = mode + 1) begin
                if (output_valid[mode] !== expected_valid)
                    $fatal(1, "mode %0d address %0d: valid %h, expected %h",
                           mode, target, output_valid[mode], expected_valid);
                for (integer lane = 0; lane < TARGETS; lane = lane + 1) begin
                    expected_data = mode == 1 && lane != target ? {WIDTH{1'b0}} : payload;
                    if (output_data[mode][lane*WIDTH +: WIDTH] !== expected_data)
                        $fatal(1, "mode %0d address %0d lane %0d: data %h, expected %h",
                               mode, target, lane, output_data[mode][lane*WIDTH +: WIDTH], expected_data);
                end
            end
        end
    endtask

    reg [WIDTH-1:0] pattern;
    integer seed = 381;

    initial begin
        seed = $urandom(seed);
        for (integer target = 0; target < TARGETS; target = target + 1) begin
            check('0, target);
            check('1, target);
            for (integer bit_index = 0; bit_index < WIDTH; bit_index = bit_index + 1) begin
                pattern = 0;
                pattern[bit_index] = 1'b1;
                check(pattern, target);
            end
            for (integer bit_index = 0; bit_index < WIDTH; bit_index = bit_index + 1)
                pattern[bit_index] = $urandom_range(0, 1);
            check(pattern, target);
        end
        $display("Sink selector %0dx%0d passed in all modes", WIDTH, TARGETS);
        $finish;
    end
endmodule
