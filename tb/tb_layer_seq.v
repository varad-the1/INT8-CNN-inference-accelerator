`timescale 1ns/1ps

// Runs conv1, conv2 and fc through layer_seq and compares EVERY result with
// the Python reference. Also reports how many clocks each layer took.
// (The inputs of each layer are loaded from Python, so the layers are checked
// independently of each other.)

module tb_layer_seq;

    localparam DATA_DIR = "data/";
    localparam NACT     = 2536;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst, go;
    wire busy, done;

    // layer configuration
    reg         cfg_fc;
    reg  [8:0]  cfg_K;
    reg  [4:0]  cfg_W, cfg_OW, cfg_nf;
    reg  [10:0] cfg_HW, cfg_wlayer;
    reg  [9:0]  cfg_npos;
    reg  [11:0] cfg_abase;
    reg  [2:0]  cfg_ngroups;
    reg  [5:0]  cfg_bbase;
    reg  signed [31:0] cfg_m0, cfg_outzp;
    reg  [4:0]  cfg_shift;
    reg  signed [7:0] cfg_zp;
    reg  [13:0] cfg_obase;

    wire [47:0] a_raddr;  wire [31:0] a_rdata;
    wire [43:0] b_raddr;  wire [31:0] b_rdata;
    wire [5:0]  bias_addr; wire signed [31:0] bias_data;
    wire        o_we;  wire [13:0] o_addr;  wire signed [7:0] o_data;

    layer_seq dut (
        .clk(clk), .rst(rst), .go(go), .busy(busy), .done(done),
        .cfg_fc(cfg_fc), .cfg_K(cfg_K), .cfg_W(cfg_W), .cfg_HW(cfg_HW), .cfg_OW(cfg_OW),
        .cfg_npos(cfg_npos), .cfg_abase(cfg_abase), .cfg_wlayer(cfg_wlayer),
        .cfg_nf(cfg_nf), .cfg_ngroups(cfg_ngroups), .cfg_bbase(cfg_bbase),
        .cfg_m0(cfg_m0), .cfg_shift(cfg_shift), .cfg_outzp(cfg_outzp), .cfg_zp(cfg_zp),
        .cfg_obase(cfg_obase),
        .a_raddr(a_raddr), .a_rdata(a_rdata), .b_raddr(b_raddr), .b_rdata(b_rdata),
        .bias_addr(bias_addr), .bias_data(bias_data),
        .o_we(o_we), .o_addr(o_addr), .o_data(o_data)
    );

    // memories
    reg         we;
    reg  [11:0] waddr;
    reg  signed [7:0] wdata;
    act_mem4 amem (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                   .raddr(a_raddr), .rdata(a_rdata));
    wrom4    wrom (.clk(clk), .raddr(b_raddr), .rdata(b_rdata));
    bias_rom brom (.addr(bias_addr), .data(bias_data));
    out_ram  outm (.clk(clk), .we(o_we), .waddr(o_addr), .wdata(o_data),
                   .raddr(14'd0), .rdata());

    reg [7:0] act_tmp [0:4095];
    reg [7:0] exp_mem [0:8191];

    integer i, errors, layer_errors, nexp, t0, t1;
    integer total_cycles;

    // run one layer and compare. Config values are set by the caller.
    task run_and_check(input [8*16-1:0] name, input integer n_expected, input [8*16-1:0] expfile);
        integer shown;
        begin
            // poison the result area so a missing write is noticed
            for (i = 0; i < 8192; i = i + 1) outm.mem[i] = 8'h55;
            $readmemh({DATA_DIR, expfile}, exp_mem);

            @(posedge clk);
            go <= 1'b1;
            t0 = $time;
            @(posedge clk);
            go <= 1'b0;
            #1;
            while (!done) @(posedge clk);
            t1 = $time;
            #1;

            layer_errors = 0;
            shown = 0;
            for (i = 0; i < n_expected; i = i + 1)
                if (outm.mem[i] !== exp_mem[i]) begin
                    layer_errors = layer_errors + 1;
                    if (shown < 5) begin
                        $display("   MISMATCH at %0d: hw=%0d expected=%0d", i,
                                 $signed(outm.mem[i]), $signed(exp_mem[i]));
                        shown = shown + 1;
                    end
                end
            errors = errors + layer_errors;
            total_cycles = total_cycles + (t1 - t0) / 10;
            $display("%0s: %0d values, %0d wrong, %0d clocks", name, n_expected,
                     layer_errors, (t1 - t0) / 10);
        end
    endtask

    initial begin
        errors = 0; total_cycles = 0;
        rst = 1'b1; go = 1'b0; we = 1'b0; waddr = 0; wdata = 0;
        cfg_zp = -8'sd128;

        $readmemh({DATA_DIR, "act_init.hex"}, act_tmp);
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        for (i = 0; i < NACT; i = i + 1) begin
            we <= 1'b1; waddr <= i; wdata <= act_tmp[i];
            @(posedge clk);
        end
        we <= 1'b0;
        @(posedge clk);

        // ---- conv1 ----
        cfg_fc = 0; cfg_K = 9;  cfg_W = 28; cfg_HW = 784; cfg_OW = 26; cfg_npos = 676;
        cfg_abase = 0;   cfg_wlayer = 0;  cfg_nf = 8;  cfg_ngroups = 2; cfg_bbase = 0;
        cfg_m0 = 32'sd2023435029; cfg_shift = 9; cfg_outzp = -32'sd128; cfg_obase = 0;
        run_and_check("conv1", 8*26*26, "expect_conv1.hex");

        // ---- conv2 ----
        cfg_fc = 0; cfg_K = 72; cfg_W = 13; cfg_HW = 169; cfg_OW = 11; cfg_npos = 121;
        cfg_abase = 784; cfg_wlayer = 18; cfg_nf = 16; cfg_ngroups = 4; cfg_bbase = 8;
        cfg_m0 = 32'sd1672637759; cfg_shift = 8; cfg_outzp = -32'sd128; cfg_obase = 0;
        run_and_check("conv2", 16*11*11, "expect_conv2.hex");

        // ---- fc ----
        cfg_fc = 1; cfg_K = 400; cfg_W = 0;  cfg_HW = 0;   cfg_OW = 0;  cfg_npos = 1;
        cfg_abase = 2136; cfg_wlayer = 306; cfg_nf = 10; cfg_ngroups = 3; cfg_bbase = 24;
        cfg_m0 = 32'sd1586550534; cfg_shift = 10; cfg_outzp = -32'sd8; cfg_obase = 0;
        run_and_check("fc", 10, "expect_fc.hex");

        $display("");
        $display("total for the three layers: %0d clocks (pooling not included)", total_cycles);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d wrong values)", errors);
        $finish;
    end

endmodule
