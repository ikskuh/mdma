module mdma_source_selector_tb #(
    parameter integer WIDTH = 64,
    parameter integer SELECT_BITS = 6
);
    localparam integer SOURCES = 2**SELECT_BITS;
    reg [SOURCES*WIDTH-1:0] data;
    reg [SOURCES-1:0] valid;
    reg [SELECT_BITS-1:0] address;
    wire [WIDTH-1:0] output_data [0:2];
    wire [2:0] output_valid;

    for (genvar mode = 0; mode < 3; mode = mode + 1) begin : implementation
        mdma_source_selector #(.WIDTH(WIDTH), .SELECT_BITS(SELECT_BITS), .IMPLEMENTATION(mode)) dut (
            .i_data(data), .i_valid(valid), .i_address(address),
            .o_data(output_data[mode]), .o_valid(output_valid[mode])
        );
    end

    task check;
        input integer source;
        begin
            address = source[SELECT_BITS-1:0];
            #1;
            for (integer mode = 0; mode < 3; mode = mode + 1) begin
                if ({output_valid[mode], output_data[mode]} !==
                        {valid[source], data[source*WIDTH +: WIDTH]})
                    $fatal(1, "mode %0d source %0d: got %b:%h, expected %b:%h",
                           mode, source, output_valid[mode], output_data[mode],
                           valid[source], data[source*WIDTH +: WIDTH]);
            end
        end
    endtask

    integer seed = 381;
    initial begin
        seed = $urandom(seed);
        for (integer source = 0; source < SOURCES; source = source + 1) begin
            // Drive complementary data and valid on all other sources so
            // a stray contribution is visible, including when selected valid is low.
            for (integer lane = 0; lane < WIDTH; lane = lane + 1) begin
                data = '0;
                data[source*WIDTH+lane] = 1'b1;
                valid = '1;
                valid[source] = 1'b0;
                check(source);
                data = ~data;
                valid = ~valid;
                check(source);
            end
        end

        for (integer pattern = 0; pattern < 12; pattern = pattern + 1) begin
            for (integer bit_index = 0; bit_index < SOURCES*WIDTH; bit_index = bit_index + 1)
                data[bit_index] = $urandom_range(0, 1);
            for (integer source = 0; source < SOURCES; source = source + 1)
                valid[source] = $urandom_range(0, 1);
            for (integer source = 0; source < SOURCES; source = source + 1)
                check(source);
        end
        $display("Source selector %0dx%0d passed in all modes", WIDTH, SOURCES);
        $finish;
    end
endmodule
