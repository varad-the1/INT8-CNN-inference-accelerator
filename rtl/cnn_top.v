// cnn_top.v
//
// The whole accelerator: load a 28x28 image, pulse `start`, wait for `done`,
// read `digit`. Replaces everything the testbench used to do around the array.
//
//   image -> conv1 -> pool1 -> conv2 -> pool2 -> fc -> argmax -> digit
//
// Image loading: while the accelerator is idle, write the 784 int8 pixels
// through load_we / load_addr / load_data (pixel y*28+x at address y*28+x).
//
// `cycles` counts clocks from `start` until `done`.

module cnn_top (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    output reg               busy,
    output reg               done,        // stays high until the next start
    output wire        [3:0] digit,
    output reg         [31:0] cycles,

    input  wire              load_we,
    input  wire [9:0]        load_addr,
    input  wire signed [7:0] load_data
);

    // ---- memory map -------------------------------------------------------
    //  activation memory:  image 0..783 | pool1 784..2135 | pool2 2136..2535
    //  out_ram:            conv1 0..5407 | conv2 5408..7343 | fc logits 7344..7353
    localparam [13:0] LOGIT_BASE = 14'd7344;

    // ---- the datapath blocks ----------------------------------------------
    wire [47:0] a_raddr;  wire [31:0] a_rdata;
    wire [43:0] b_raddr;  wire [31:0] b_rdata;
    wire [5:0]  bias_addr; wire signed [31:0] bias_data;
    wire        l_we;  wire [13:0] l_addr;  wire signed [7:0] l_data;
    wire        p_we;  wire [11:0] p_addr;  wire signed [7:0] p_data;
    wire [13:0] p_raddr;
    wire signed [7:0] o_rdata;

    // layer configuration, chosen by `step`
    reg         c_fc;
    reg  [8:0]  c_K;
    reg  [4:0]  c_W, c_OW, c_nf;
    reg  [10:0] c_HW, c_wlayer;
    reg  [9:0]  c_npos;
    reg  [11:0] c_abase;
    reg  [2:0]  c_ngroups;
    reg  [5:0]  c_bbase;
    reg  signed [31:0] c_m0, c_outzp;
    reg  [4:0]  c_shift;
    reg  [13:0] c_obase;

    // pooling configuration
    reg  [13:0] q_src;
    reg  [11:0] q_dst;
    reg  [4:0]  q_in, q_out, q_ch;

    reg [2:0] step;                         // 0 conv1, 1 pool1, 2 conv2, 3 pool2, 4 fc
    reg [2:0] state;
    reg       lgo, pgo;
    wire      l_busy, l_done, p_busy, p_done;

    always @(*) begin
        c_fc = 1'b0; c_K = 9; c_W = 28; c_HW = 784; c_OW = 26; c_npos = 676;
        c_abase = 12'd0; c_wlayer = 11'd0; c_nf = 8; c_ngroups = 2; c_bbase = 6'd0;
        c_m0 = 32'sd2023435029; c_shift = 5'd9; c_outzp = -32'sd128; c_obase = 14'd0;
        case (step)
            3'd2: begin                                         // conv2
                c_K = 72; c_W = 13; c_HW = 169; c_OW = 11; c_npos = 121;
                c_abase = 12'd784; c_wlayer = 11'd18; c_nf = 16; c_ngroups = 4; c_bbase = 6'd8;
                c_m0 = 32'sd1672637759; c_shift = 5'd8; c_obase = 14'd5408;
            end
            3'd4: begin                                         // fc
                c_fc = 1'b1; c_K = 400; c_W = 0; c_HW = 0; c_OW = 0; c_npos = 1;
                c_abase = 12'd2136; c_wlayer = 11'd306; c_nf = 10; c_ngroups = 3; c_bbase = 6'd24;
                c_m0 = 32'sd1586550534; c_shift = 5'd10; c_outzp = -32'sd8; c_obase = LOGIT_BASE;
            end
            default: ;                                          // conv1 values above
        endcase

        q_src = 14'd0;    q_dst = 12'd784;  q_in = 26; q_out = 13; q_ch = 8;     // pool1
        if (step == 3'd3) begin
            q_src = 14'd5408; q_dst = 12'd2136; q_in = 11; q_out = 5; q_ch = 16; // pool2
        end
    end

    layer_seq lseq (
        .clk(clk), .rst(rst), .go(lgo), .busy(l_busy), .done(l_done),
        .cfg_fc(c_fc), .cfg_K(c_K), .cfg_W(c_W), .cfg_HW(c_HW), .cfg_OW(c_OW),
        .cfg_npos(c_npos), .cfg_abase(c_abase), .cfg_wlayer(c_wlayer),
        .cfg_nf(c_nf), .cfg_ngroups(c_ngroups), .cfg_bbase(c_bbase),
        .cfg_m0(c_m0), .cfg_shift(c_shift), .cfg_outzp(c_outzp), .cfg_zp(-8'sd128),
        .cfg_obase(c_obase),
        .a_raddr(a_raddr), .a_rdata(a_rdata), .b_raddr(b_raddr), .b_rdata(b_rdata),
        .bias_addr(bias_addr), .bias_data(bias_data),
        .o_we(l_we), .o_addr(l_addr), .o_data(l_data)
    );

    pool_seq pseq (
        .clk(clk), .rst(rst), .go(pgo), .busy(p_busy), .done(p_done),
        .cfg_src_base(q_src), .cfg_dst_base(q_dst),
        .cfg_in_n(q_in), .cfg_out_n(q_out), .cfg_ch(q_ch),
        .r_addr(p_raddr), .r_data(o_rdata),
        .o_we(p_we), .o_addr(p_addr), .o_data(p_data)
    );

    // activation memory: the image comes in through the load port while idle,
    // pooled maps come from pool_seq while it runs
    wire        a_we    = p_busy ? p_we   : load_we;
    wire [11:0] a_waddr = p_busy ? p_addr : {2'b00, load_addr};
    wire signed [7:0] a_wdata = p_busy ? p_data : load_data;
    act_mem4 amem (.clk(clk), .we(a_we), .waddr(a_waddr), .wdata(a_wdata),
                   .raddr(a_raddr), .rdata(a_rdata));

    wrom4    wrom (.clk(clk), .raddr(b_raddr), .rdata(b_rdata));
    bias_rom brom (.addr(bias_addr), .data(bias_data));

    // conv / logit results; read by pool_seq, and by the argmax reader below
    reg  [13:0] ra;                                  // argmax reader address
    reg         sel_arg;
    out_ram outm (.clk(clk), .we(l_we), .waddr(l_addr), .wdata(l_data),
                  .raddr(sel_arg ? ra : p_raddr), .rdata(o_rdata));

    // ---- argmax: read the 10 logits one per clock -------------------------
    reg [3:0] rcnt;
    reg       av1, av2, al1, al2;                    // valid / last, aligned with ra, then with o_rdata
    wire      am_done;
    argmax10 amax (.clk(clk), .rst(rst), .valid_in(av2), .score(o_rdata), .last(al2),
                   .done(am_done), .digit(digit));

    // ---- control ----------------------------------------------------------
    localparam S_IDLE = 3'd0, S_GO = 3'd1, S_GO2 = 3'd2, S_WAIT = 3'd3,
               S_ARG  = 3'd4, S_ARGW = 3'd5;
    wire is_pool = (step == 3'd1) || (step == 3'd3);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;  busy <= 1'b0;  done <= 1'b0;
            lgo <= 1'b0;  pgo <= 1'b0;  sel_arg <= 1'b0;
            av1 <= 1'b0;  av2 <= 1'b0;  al1 <= 1'b0;  al2 <= 1'b0;
            cycles <= 32'd0;
        end else begin
            lgo <= 1'b0;  pgo <= 1'b0;                  // one-clock pulses
            av2 <= av1;   al2 <= al1;
            av1 <= 1'b0;  al1 <= 1'b0;
            if (busy) cycles <= cycles + 32'd1;

            case (state)
            S_IDLE: if (start) begin
                busy   <= 1'b1;
                done   <= 1'b0;
                cycles <= 32'd0;
                step   <= 3'd0;
                state  <= S_GO;
            end

            S_GO: begin                                  // pulse go to the current stage
                if (is_pool) pgo <= 1'b1; else lgo <= 1'b1;
                state <= S_GO2;
            end

            S_GO2: state <= S_WAIT;                      // stage samples go and clears its old done

            S_WAIT: if (is_pool ? p_done : l_done) begin
                if (step == 3'd4) begin
                    rcnt    <= 4'd0;
                    sel_arg <= 1'b1;
                    state   <= S_ARG;
                end else begin
                    step  <= step + 3'd1;
                    state <= S_GO;
                end
            end

            S_ARG: begin                                 // read the 10 logits
                ra  <= LOGIT_BASE + {10'd0, rcnt};
                av1 <= 1'b1;
                al1 <= (rcnt == 4'd9);
                rcnt <= rcnt + 4'd1;
                if (rcnt == 4'd9) state <= S_ARGW;
            end

            S_ARGW: if (am_done) begin
                sel_arg <= 1'b0;
                busy    <= 1'b0;
                done    <= 1'b1;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
