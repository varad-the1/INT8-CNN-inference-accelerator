// tile_engine.v
//
// Computes ONE 4x4 tile: 4 image patches x 4 filters, K multiply-accumulates
// each, on the systolic array. Hardware version of what the testbench did in
// the A/B-building loops plus systolic_matmul_4xK.
//
// What it does, in order:
//   1. pulse the array's reset (clears all 16 accumulators)
//   2. for K+3 clocks, read activations (4 rows) and weights (4 columns) from
//      the memories, with row r / column c starting r / c clocks late (skew)
//   3. wait for the data to ripple through the array (3 more clocks)
//   4. raise `done`; c_flat then holds the 16 sums (bias NOT added yet)
//
// Activation address for row r:   base_r + offset(k - r)
//   base_r    start of that row's patch in the input map (conv), or abase (fc)
//   offset(k) ch*H*W + kh*W + kw   -> counters kw, kh, ch  (common to all rows)
// Weight address for column c:     wbase + (k - c)
//
// Memory pipeline per side:  address register -> memory output -> subtract
// zero-point -> array input.  Out-of-range slots feed 0, as the testbench did.

module tile_engine (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,

    // layer configuration (sampled when `start` is high)
    input  wire         cfg_fc,      // 1: fully connected (linear k, same base for all rows)
    input  wire [8:0]   cfg_K,       // multiply-accumulates per output: 9, 72 or 400
    input  wire [4:0]   cfg_W,       // input map width      (conv)
    input  wire [10:0]  cfg_HW,      // input map height*width (conv)
    input  wire [4:0]   cfg_OW,      // output map width     (conv)
    input  wire [9:0]   cfg_npos,    // number of output positions in the layer
    input  wire [11:0]  cfg_abase,   // where the input map starts in the activation memory
    input  wire [10:0]  cfg_wbase,   // weight ROM address of this filter group's first weight
    input  wire signed [7:0] cfg_zp, // input zero-point

    // which tile (sampled when `start` is high)
    input  wire [9:0]   pos0,        // linear position of patch 0
    input  wire [4:0]   py0,         // its row ...
    input  wire [4:0]   px0,         // ... and column in the output map

    // memories
    output wire [47:0]  a_raddr,     // 4 x 12-bit activation read addresses
    input  wire [31:0]  a_rdata,     // 4 x 8-bit activation data (1 clock later)
    output wire [43:0]  b_raddr,     // 4 x 11-bit weight read addresses
    input  wire [31:0]  b_rdata,     // 4 x 8-bit weights (1 clock later)

    output reg          busy,
    output reg          done,        // stays high until the next start
    output wire [511:0] c_flat       // 16 x 32-bit sums, {C33 .. C00}
);

    localparam S_IDLE = 2'd0, S_PREP = 2'd1, S_RUN = 2'd2;
    reg [1:0] state;
    reg [9:0] n;                     // slot counter, 0 .. K+8

    // latched configuration
    reg               fc_r;
    reg [8:0]         k_r;
    reg [4:0]         w_r, ow_r;
    reg [10:0]        hw_r;
    reg [9:0]         npos_r, pos0_r;
    reg [11:0]        abase_r;
    reg [10:0]        wbase_r;
    reg signed [7:0]  zp_r;
    reg [4:0]         py0_r, px0_r;

    reg               arr_rst;

    // ---- activation offset generator (kw, kh, channel counters) -----------
    reg  [1:0]  kw, kh;
    reg  [11:0] off, o1, o2, o3;     // o1..o3 = off delayed 1..3 clocks (for rows 1..3)

    // ---- weight address and its delays (for columns 1..3) ----------------
    wire [10:0] w0 = wbase_r + n[8:0];
    reg  [10:0] w1, w2, w3;

    always @(posedge clk) begin
        o1 <= off;  o2 <= o1;  o3 <= o2;
        w1 <= w0;   w2 <= w1;  w3 <= w2;
    end

    // ---- control ---------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            arr_rst <= 1'b0;
            n       <= 10'd0;
            kw <= 2'd0; kh <= 2'd0; off <= 12'd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    fc_r    <= cfg_fc;
                    k_r     <= cfg_K;
                    w_r     <= cfg_W;
                    hw_r    <= cfg_HW;
                    ow_r    <= cfg_OW;
                    npos_r  <= cfg_npos;
                    abase_r <= cfg_abase;
                    wbase_r <= cfg_wbase;
                    zp_r    <= cfg_zp;
                    pos0_r  <= pos0;
                    py0_r   <= py0;
                    px0_r   <= px0;
                    busy    <= 1'b1;
                    done    <= 1'b0;
                    arr_rst <= 1'b1;          // clear the accumulators
                    state   <= S_PREP;
                end
            end

            S_PREP: begin                     // row bases are captured on this edge
                arr_rst <= 1'b0;
                n   <= 10'd0;
                kw  <= 2'd0;
                kh  <= 2'd0;
                off <= 12'd0;
                state <= S_RUN;
            end

            S_RUN: begin
                n <= n + 10'd1;
                // advance the offset: next kw, next kh, or next channel
                if (fc_r) begin
                    off <= off + 12'd1;
                end else if (kw != 2'd2) begin
                    kw  <= kw + 2'd1;
                    off <= off + 12'd1;
                end else begin
                    kw <= 2'd0;
                    if (kh != 2'd2) begin
                        kh  <= kh + 2'd1;
                        off <= off + {7'd0, w_r} - 12'd2;
                    end else begin
                        kh  <= 2'd0;
                        off <= off + {1'b0, hw_r} - {6'd0, w_r, 1'b0} - 12'd2;
                    end
                end
                if (n == {1'b0, k_r} + 10'd8) begin
                    state <= S_IDLE;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ---- per-row logic (activation side) -----------------------------------
    wire [9:0]  rowoff = py0_r * w_r;                 // py0 * W, used for the row bases
    wire [63:0] a_in_flat;

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : rowg
            // where this row's patch starts
            wire [9:0]  pos_s  = pos0_r + g;
            wire [5:0]  px_s   = {1'b0, px0_r} + g;
            wire        wrap   = (px_s >= {1'b0, ow_r});      // patch moved to the next row
            wire [5:0]  px_f   = wrap ? (px_s - {1'b0, ow_r}) : px_s;
            wire [11:0] base_n = fc_r ? abase_r
                                      : (abase_r + rowoff + (wrap ? w_r : 5'd0) + px_f);
            wire        pv_n   = (pos_s < npos_r);            // patch exists (not past the last)

            reg [11:0] base_q;
            reg        pv_q;
            always @(posedge clk)
                if (state == S_PREP) begin
                    base_q <= base_n;
                    pv_q   <= pv_n;
                end

            // this row starts g clocks late and runs for K clocks
            wire active = (n >= g) && (n < k_r + g);
            wire [11:0] og = (g == 0) ? off : (g == 1) ? o1 : (g == 2) ? o2 : o3;
            wire        go = (state == S_RUN) && active && pv_q;

            reg [11:0]        addr_q;
            reg               v1, v2;
            reg signed [15:0] din;
            always @(posedge clk) begin
                addr_q <= go ? (base_q + og) : 12'd0;
                v1     <= go;
                v2     <= v1;
                din    <= v2 ? ($signed({{8{a_rdata[8*g+7]}}, a_rdata[8*g +: 8]})
                                 - $signed({{8{zp_r[7]}}, zp_r}))
                             : 16'sd0;
            end
            assign a_raddr[12*g +: 12] = addr_q;
            assign a_in_flat[16*g +: 16] = din;
        end
    endgenerate

    // ---- per-column logic (weight side) -----------------------------------
    wire [63:0] b_in_flat;

    generate
        for (g = 0; g < 4; g = g + 1) begin : colg
            wire active = (n >= g) && (n < k_r + g);
            wire [10:0] wg = (g == 0) ? w0 : (g == 1) ? w1 : (g == 2) ? w2 : w3;
            wire        go = (state == S_RUN) && active;

            reg [10:0]        addr_q;
            reg               v1, v2;
            reg signed [15:0] din;
            always @(posedge clk) begin
                addr_q <= go ? wg : 11'd0;
                v1     <= go;
                v2     <= v1;
                din    <= v2 ? $signed({{8{b_rdata[8*g+7]}}, b_rdata[8*g +: 8]}) : 16'sd0;
            end
            assign b_raddr[11*g +: 11] = addr_q;
            assign b_in_flat[16*g +: 16] = din;
        end
    endgenerate

    // ---- the systolic array ------------------------------------------------
    wire signed [31:0] C_00, C_01, C_02, C_03, C_10, C_11, C_12, C_13;
    wire signed [31:0] C_20, C_21, C_22, C_23, C_30, C_31, C_32, C_33;

    SystolicArrayMod #(.DATA_WIDTH(16), .ACC_WIDTH(32), .ROW(4), .COL(4)) array (
        .Clk   (clk),
        .Rst   (arr_rst),
        .A_row0(a_in_flat[15:0]),  .A_row1(a_in_flat[31:16]),
        .A_row2(a_in_flat[47:32]), .A_row3(a_in_flat[63:48]),
        .B_col0(b_in_flat[15:0]),  .B_col1(b_in_flat[31:16]),
        .B_col2(b_in_flat[47:32]), .B_col3(b_in_flat[63:48]),
        .C_00(C_00), .C_01(C_01), .C_02(C_02), .C_03(C_03),
        .C_10(C_10), .C_11(C_11), .C_12(C_12), .C_13(C_13),
        .C_20(C_20), .C_21(C_21), .C_22(C_22), .C_23(C_23),
        .C_30(C_30), .C_31(C_31), .C_32(C_32), .C_33(C_33)
    );

    assign c_flat = { C_33, C_32, C_31, C_30,
                      C_23, C_22, C_21, C_20,
                      C_13, C_12, C_11, C_10,
                      C_03, C_02, C_01, C_00 };

endmodule
