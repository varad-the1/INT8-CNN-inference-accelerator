// pool_seq.v
//
// 2x2 max-pool of a whole layer. Hardware version of maxpool1 / maxpool2 in
// tb_microcnn.v.
//
// Reads a conv output (channel-major, from out_ram), takes the max of every
// 2x2 window with maxpool4, and writes the pooled map into the activation
// memory (act_mem4 write port), channel-major: dst_base + ch*OUT*OUT + y*OUT + x.
// Square maps only (26x26 -> 13x13, 11x11 -> 5x5; the odd last row/column of
// 11x11 is simply never read, as in the testbench).
//
// One memory read per clock, so one window every 4 clocks. Reads, the 4-value
// shift register, maxpool4 and the write are pipelined; windows follow each
// other back to back.
//
// Hold the cfg_* inputs steady while `busy` is high. Pulse `go` to start.

module pool_seq (
    input  wire         clk,
    input  wire         rst,
    input  wire         go,
    output reg          busy,
    output reg          done,

    input  wire [13:0]  cfg_src_base,   // conv output start in out_ram
    input  wire [11:0]  cfg_dst_base,   // pooled output start in the activation memory
    input  wire [4:0]   cfg_in_n,       // input map is IN x IN   (26 or 11)
    input  wire [4:0]   cfg_out_n,      // output map is OUT x OUT (13 or 5)
    input  wire [4:0]   cfg_ch,         // number of channels      (8 or 16)

    // source memory read port (synchronous: data one clock after address)
    output reg  [13:0]  r_addr,
    input  wire signed [7:0] r_data,

    // destination write port
    output wire         o_we,
    output wire [11:0]  o_addr,
    output wire signed [7:0] o_data
);

    // address steps, from the configuration
    wire [13:0] in14   = {9'd0, cfg_in_n};
    wire [13:0] last   = {9'd0, cfg_out_n} - 14'd1;               // OUT-1
    // The steps are computed from the (steady) configuration and registered, so
    // the multiplier is not in the same clock cycle as the address update.
    reg  [13:0] row_step;              // end of a window row -> start of the next
    reg  [13:0] ch_step;               // last window of a channel -> next channel
    always @(posedge clk) begin
        row_step <= (in14 << 1) - (last << 1);
        ch_step  <= in14 * in14 - ((last << 1) * in14) - (last << 1);
    end

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FLUSH = 2'd2;
    reg [1:0] state;

    reg [13:0] wa;                     // address of the top-left pixel of the current window
    reg [1:0]  j;                      // which of the 4 pixels of the window
    reg [4:0]  ox, oy, ch;
    reg [11:0] dstw;                   // destination address of the current window
    reg [3:0]  fcnt;

    wire [13:0] off_j = (j == 2'd0) ? 14'd0 :
                        (j == 2'd1) ? 14'd1 :
                        (j == 2'd2) ? in14 : (in14 + 14'd1);

    wire last_col = (ox == cfg_out_n - 5'd1);
    wire last_row = (oy == cfg_out_n - 5'd1);
    wire last_ch  = (ch == cfg_ch - 5'd1);

    // tags travelling with the read: "last pixel of a window" and its destination
    reg        l1, l2, l3;
    reg [11:0] d1, d2, d3, d4;

    // the last 4 values read: s3 oldest ... s0 newest
    reg signed [7:0] s0, s1, s2, s3;

    wire        mp_valid;
    wire signed [7:0] mp_y;
    maxpool4 mp (.clk(clk), .valid_in(l3), .a(s3), .b(s2), .c(s1), .d(s0),
                 .valid_out(mp_valid), .y(mp_y));

    assign o_we   = mp_valid;
    assign o_addr = d4;
    assign o_data = mp_y;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            done  <= 1'b0;
            l1 <= 1'b0;
            r_addr <= 14'd0;
        end else begin
            // ---- read pipeline (runs every clock) ----
            l2 <= l1;   l3 <= l2;
            d2 <= d1;   d3 <= d2;   d4 <= d3;
            s0 <= r_data;  s1 <= s0;  s2 <= s1;  s3 <= s2;
            l1 <= 1'b0;                              // default; set below while issuing

            case (state)
            S_IDLE: if (go) begin
                busy  <= 1'b1;
                done  <= 1'b0;
                wa    <= cfg_src_base;
                j     <= 2'd0;
                ox    <= 5'd0;  oy <= 5'd0;  ch <= 5'd0;
                dstw  <= cfg_dst_base;
                state <= S_RUN;
            end

            S_RUN: begin
                r_addr <= wa + off_j;                // issue one read
                l1     <= (j == 2'd3);
                d1     <= dstw;
                j      <= j + 2'd1;
                if (j == 2'd3) begin                 // finished issuing a window: move on
                    dstw <= dstw + 12'd1;
                    if (!last_col) begin
                        ox <= ox + 5'd1;
                        wa <= wa + 14'd2;
                    end else begin
                        ox <= 5'd0;
                        if (!last_row) begin
                            oy <= oy + 5'd1;
                            wa <= wa + row_step;
                        end else begin
                            oy <= 5'd0;
                            if (!last_ch) begin
                                ch <= ch + 5'd1;
                                wa <= wa + ch_step;
                            end else begin
                                fcnt  <= 4'd0;
                                state <= S_FLUSH;
                            end
                        end
                    end
                end
            end

            S_FLUSH: begin                           // let the last window reach the memory
                fcnt <= fcnt + 4'd1;
                if (fcnt == 4'd7) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
