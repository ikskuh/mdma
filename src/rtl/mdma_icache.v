// Read-only bus cache: 4 KiB, two ways, 64 sets, four words per line.
// Frontend is pipelined Wishbone; backend is single-outstanding Classic.
// Dropping s_cyc cancels frontend work. An issued backend beat drains,
// but its data/error cannot acknowledge or populate a later cycle.
module mdma_icache (
    input wire clk, reset,
    input wire s_cyc, s_stb,
    input wire [63:0] s_adr,
    output wire s_stall,
    output wire [63:0] s_dat,
    output wire s_ack, s_err,
    output wire wb_cyc, wb_stb,
    output wire [63:0] wb_adr,
    input wire [63:0] wb_dat,
    input wire wb_ack, wb_err
);
    (* ram_style = "block" *) reg [63:0] data0 [0:255], data1 [0:255];
    reg [52:0] tag0 [0:63], tag1 [0:63];
    reg [3:0] valid0 [0:63], valid1 [0:63];
    reg [63:0] victim;
    reg [63:0] requests [0:3];
    reg [1:0] read_pointer, write_pointer;
    reg [2:0] count;
    reg lookup_valid, hit0, hit1, lookup_way;
    reg [63:0] lookup_address, read0, read1;
    reg miss_valid, miss_error;
    reg [63:0] miss_data;
    reg busy, orphaned, refill_way;
    reg [63:0] refill_address;

    wire hit = hit0 || hit1;
    wire response = s_cyc && lookup_valid && (hit || miss_valid);
    assign s_ack = response && !(miss_valid && miss_error);
    assign s_err = response && miss_valid && miss_error;
    assign s_dat = hit ? (hit0 ? read0 : read1) : miss_data;
    assign s_stall = count == 4;
    wire accept = s_cyc && s_stb && !s_stall;
    // An empty request queue is bypassed: a ready lookup goes straight to
    // the synchronous RAM port. Queue only requests blocked by an older miss.
    wire lookup = s_cyc && (count != 0 || accept) && (!lookup_valid || response);
    wire dequeue = lookup && count != 0;
    wire enqueue = accept && !(lookup && count == 0);
    wire [63:0] address = count != 0 ? requests[read_pointer] : s_adr;
    wire [5:0] index = address[10:5];
    wire match0 = |valid0[index] && tag0[index] == address[63:11];
    wire match1 = |valid1[index] && tag1[index] == address[63:11];
    wire miss_start = s_cyc && lookup_valid && !hit && !miss_valid && !busy;
    wire [5:0] refill_index = refill_address[10:5];
    assign wb_cyc = busy;
    assign wb_stb = busy;
    assign wb_adr = refill_address;

    // A live fill completes before the next lookup. Orphaned fills do not
    // write RAM, so target hits can run while a canceled beat drains.
    always @(posedge clk) begin
        if (lookup) begin
            read0 <= data0[address[10:3]];
            read1 <= data1[address[10:3]];
        end
        if (busy && wb_ack && !wb_err && s_cyc && !orphaned && !reset) begin
            if (refill_way)
                data1[refill_address[10:3]] <= wb_dat;
            else
                data0[refill_address[10:3]] <= wb_dat;
        end
    end

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            count <= 0;
            read_pointer <= 0;
            write_pointer <= 0;
            lookup_valid <= 0;
            miss_valid <= 0;
            busy <= 0;
            orphaned <= 0;
            victim <= 0;
            for (i = 0; i < 64; i = i + 1) begin
                valid0[i] <= 0;
                valid1[i] <= 0;
            end
        end else begin
            if (busy && (wb_ack || wb_err)) begin
                busy <= 0;
                if (s_cyc && !orphaned) begin
                    miss_valid <= 1;
                    miss_error <= wb_err;
                    miss_data <= wb_dat;
                    if (wb_ack && !wb_err) begin
                        if (refill_way) begin
                            tag1[refill_index] <= refill_address[63:11];
                            valid1[refill_index] <=
                                ((tag1[refill_index] == refill_address[63:11]) ? valid1[refill_index] : 4'b0) |
                                (4'b1 << refill_address[4:3]);
                        end else begin
                            tag0[refill_index] <= refill_address[63:11];
                            valid0[refill_index] <=
                                ((tag0[refill_index] == refill_address[63:11]) ? valid0[refill_index] : 4'b0) |
                                (4'b1 << refill_address[4:3]);
                        end
                        victim[refill_index] <= !refill_way;
                    end
                end
            end
            if (!s_cyc) begin
                count <= 0;
                read_pointer <= 0;
                write_pointer <= 0;
                lookup_valid <= 0;
                miss_valid <= 0;
                if (busy)
                    orphaned <= 1;
            end else begin
                count <= count + {2'b0, enqueue} - {2'b0, dequeue};
                if (enqueue) begin
                    requests[write_pointer] <= s_adr;
                    write_pointer <= write_pointer + 1'b1;
                end
                if (response) begin
                    lookup_valid <= 0;
                    miss_valid <= 0;
                    if (hit)
                        victim[lookup_address[10:5]] <= hit0;
                end
                if (lookup) begin
                    if (dequeue)
                        read_pointer <= read_pointer + 1'b1;
                    lookup_valid <= 1;
                    lookup_address <= address;
                    hit0 <= match0 && valid0[index][address[4:3]];
                    hit1 <= match1 && valid1[index][address[4:3]];
                    lookup_way <= match0 ? 1'b0 : match1 ? 1'b1 :
                                  ((|valid0[index]) && (!(|valid1[index]) || victim[index]));
                end
                if (miss_start) begin
                    busy <= 1;
                    orphaned <= 0;
                    refill_address <= lookup_address;
                    refill_way <= lookup_way;
                end
            end
        end
    end
endmodule
