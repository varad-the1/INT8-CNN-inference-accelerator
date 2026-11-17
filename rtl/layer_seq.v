// layer_seq.v
//
// Runs ONE layer (conv1, conv2 or fc) to completion, one tile at a time.
// Hardware version of the loops in run_conv1 / run_conv2 / run_fc of
// tb_microcnn.v:
//
//   for each group of 4 filters:
//     for each group of 4 patches:
//        run a tile on the systolic array            (tile_engine)
//        for the 16 sums:  add bias -> requantize -> write int8 to memory
//
// Simplest correct version: the next tile starts only after the 16 results
// of the previous one are written. (Overlapping them is a later optimisation.)
//
// Hold the cfg_* inputs steady while `busy` is high. Pulse `go` to start.
// `done` goes high when the last result is in memory and stays high until the
// next `go`.
//
// Result layout: address = cfg_obase + filter*npos + position (channel-major).
// For fc, set npos = 1: logit o lands at cfg_obase + o.

module layer_seq (
    input  wire         clk,
    input  wire         rst,
    input  wire         go,
    output reg          busy,
    output reg          done,

    // layer configuration
    input  wire         cfg_fc,
    input  wire [8:0]   cfg_K,
    input  wire [4:0]   cfg_W,
    input  wire [10:0]  cfg_HW,
    input  wire [4:0]   cfg_OW,
    input  wire [9:0]   cfg_npos,
    input  wire [11:0]  cfg_abase,      // input map start in the activation memory
    input  wire [10:0]  cfg_wlayer,     // first weight of this layer in the weight ROM
    input  wire [4:0]   cfg_nf,         // real number of filters (8, 16 or 10)
    input  wire [2:0]   cfg_ngroups,    // ceil(nf / 4)
    input  wire [5:0]   cfg_bbase,      // first bias of this layer in the bias ROM
    input  wire signed [31:0] cfg_m0,
    input  wire [4:0]   cfg_shift,      // right shift
    input  wire signed [31:0] cfg_outzp,
    input  wire signed [7:0]  cfg_zp,   // input zero-point
    input  wire [13:0]  cfg_obase,      // where this layer's results go

    // memories
    output wire [47:0]  a_raddr,
    input  wire [31:0]  a_rdata,
    output wire [43:0]  b_raddr,
    input  wire [31:0]  b_rdata,
    output wire [5:0]   bias_addr,
    input  wire signed [31:0] bias_data,

    // result write port
    output wire         o_we,
    output wire [13:0]  o_addr,
    output wire signed [7:0] o_data
);

    localparam S_IDLE = 3'd0, S_LAUNCH = 3'd1, S_L2 = 3'd2, S_WAIT = 3'd3,
               S_SER  = 3'd4, S_DRAIN  = 3'd5, S_NEXT = 3'd6;
    reg [2:0] state;

    // where we are in the layer
    reg [9:0]  pos0;                 // first of the 4 patches
    reg [4:0]  py0, px0;
    reg [2:0]  g;                    // filter group
    reg [4:0]  obase;                // first filter of the group (= 4*g)
    reg [10:0] wbase;                // weight ROM address of the group
    reg [13:0] oo;                   // obase * npos (output address offset of the group)
    reg [4:0]  i;                    // which of the 16 sums is being sent
    reg [2:0]  dcnt;

    reg start_r;
    wire eng_busy, eng_done;
    wire [511:0] c_flat;

    tile_engine eng (
        .clk(clk), .rst(rst), .start(start_r),
        .cfg_fc(cfg_fc), .cfg_K(cfg_K), .cfg_W(cfg_W), .cfg_HW(cfg_HW), .cfg_OW(cfg_OW),
        .cfg_npos(cfg_npos), .cfg_abase(cfg_abase), .cfg_wbase(wbase), .cfg_zp(cfg_zp),
        .pos0(pos0), .py0(py0), .px0(px0),
        .a_raddr(a_raddr), .a_rdata(a_rdata), .b_raddr(b_raddr), .b_rdata(b_rdata),
        .busy(eng_busy), .done(eng_done), .c_flat(c_flat)
    );

    // ---- the 16 sums, one per clock: filter c = i[1:0], patch r = i[3:2] ----
    wire [1:0]  c_idx = i[1:0];
    wire [1:0]  r_idx = i[3:2];
    assign bias_addr = cfg_bbase + {1'b0, obase} + {4'd0, c_idx};

    wire [13:0] np   = {4'd0, cfg_npos};
    wire [13:0] cnp  = (c_idx == 2'd0) ? 14'd0 :
                       (c_idx == 2'd1) ? np :
                       (c_idx == 2'd2) ? (np << 1) : (np + (np << 1));
    wire [13:0] addr_n = cfg_obase + oo + cnp + {4'd0, pos0} + {12'd0, r_idx};
    wire        elem_ok = (({1'b0, pos0} + r_idx) < {1'b0, cfg_npos}) &&
                          (({1'b0, obase} + c_idx) < {1'b0, cfg_nf});

    // stage 0: sum + bias, registered
    reg               v0, we0;
    reg signed [31:0] acc0;
    reg        [13:0] da0;

    // requantizer (3 clocks) and matching address / write-enable delay line
    wire signed [7:0] rq_result;
    wire              rq_valid;
    requantizer rq (
        .clk(clk), .valid_in(v0), .acc(acc0), .m0(cfg_m0), .shift_r(cfg_shift),
        .out_zp(cfg_outzp), .valid_out(rq_valid), .result(rq_result)
    );

    reg [13:0] da1, da2, da3, da4, da5;
    reg        we1, we2, we3, we4, we5;
    always @(posedge clk) begin
        da1 <= da0;  da2 <= da1;  da3 <= da2;  da4 <= da3;  da5 <= da4;
        we1 <= we0;  we2 <= we1;  we3 <= we2;  we4 <= we3;  we5 <= we4;
    end
    assign o_we   = we5;
    assign o_addr = da5;
    assign o_data = rq_result;

    // ---- control -----------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            start_r <= 1'b0;
            v0 <= 1'b0;  we0 <= 1'b0;
        end else begin
            start_r <= 1'b0;                 // defaults: pulses last one clock
            v0      <= 1'b0;
            we0     <= 1'b0;

            case (state)
            S_IDLE: if (go) begin
                busy  <= 1'b1;
                done  <= 1'b0;
                pos0  <= 10'd0;  py0 <= 5'd0;  px0 <= 5'd0;
                g     <= 3'd0;   obase <= 5'd0;
                wbase <= cfg_wlayer;
                oo    <= 14'd0;
                state <= S_LAUNCH;
            end

            S_LAUNCH: begin                  // tell the engine to start this tile
                start_r <= 1'b1;
                state   <= S_L2;
            end

            S_L2: state <= S_WAIT;           // engine samples `start`, clears its old done

            S_WAIT: if (eng_done) begin      // 16 sums are ready in c_flat
                i     <= 5'd0;
                state <= S_SER;
            end

            S_SER: begin                     // send the 16 sums down the pipeline
                v0   <= 1'b1;
                acc0 <= $signed(c_flat[i*32 +: 32]) + bias_data;
                da0  <= addr_n;
                we0  <= elem_ok;
                i    <= i + 5'd1;
                if (i == 5'd15) begin
                    dcnt  <= 3'd0;
                    state <= S_DRAIN;
                end
            end

            S_DRAIN: begin                   // let the last result reach the memory
                dcnt <= dcnt + 3'd1;
                if (dcnt == 3'd5) state <= S_NEXT;
            end

            S_NEXT: begin
                if ((pos0 + 10'd4) < cfg_npos) begin            // next 4 patches
                    pos0 <= pos0 + 10'd4;
                    if (({1'b0, px0} + 6'd4) >= {1'b0, cfg_OW}) begin
                        px0 <= px0 + 5'd4 - cfg_OW;
                        py0 <= py0 + 5'd1;
                    end else begin
                        px0 <= px0 + 5'd4;
                    end
                    state <= S_LAUNCH;
                end else if ((g + 3'd1) < cfg_ngroups) begin    // next 4 filters
                    g     <= g + 3'd1;
                    obase <= obase + 5'd4;
                    wbase <= wbase + {2'd0, cfg_K};
                    oo    <= oo + (np << 2);
                    pos0  <= 10'd0;  py0 <= 5'd0;  px0 <= 5'd0;
                    state <= S_LAUNCH;
                end else begin                                  // layer finished
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
