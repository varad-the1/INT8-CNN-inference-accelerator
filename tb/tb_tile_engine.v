`timescale 1ns/1ps

// Checks tile_engine.v (feeder + memories + systolic array) tile by tile.
// Expected sums come from reference/gen_tile_vectors.py, which builds the A and
// B matrices the same way tb_microcnn.v does and multiplies them in Python.

module tb_tile_engine;

    localparam DATA_DIR = "data/";
    localparam NACT     = 2536;          // 784 image + 1352 pool1 + 400 pool2
    localparam MAXT     = 400;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT and memories ----
    reg         rst, start;
    reg         cfg_fc;
    reg  [8:0]  cfg_K;
    reg  [4:0]  cfg_W, cfg_OW;
    reg  [10:0] cfg_HW, cfg_wbase;
    reg  [9:0]  cfg_npos, pos0;
    reg  [11:0] cfg_abase;
    reg  signed [7:0] cfg_zp;
    reg  [4:0]  py0, px0;

    wire [47:0] a_raddr;  wire [31:0] a_rdata;
    wire [43:0] b_raddr;  wire [31:0] b_rdata;
    wire        busy, done;
    wire [511:0] c_flat;

    reg         we;
    reg  [11:0] waddr;
    reg  signed [7:0] wdata;

    tile_engine dut (
        .clk(clk), .rst(rst), .start(start),
        .cfg_fc(cfg_fc), .cfg_K(cfg_K), .cfg_W(cfg_W), .cfg_HW(cfg_HW), .cfg_OW(cfg_OW),
        .cfg_npos(cfg_npos), .cfg_abase(cfg_abase), .cfg_wbase(cfg_wbase), .cfg_zp(cfg_zp),
        .pos0(pos0), .py0(py0), .px0(px0),
        .a_raddr(a_raddr), .a_rdata(a_rdata), .b_raddr(b_raddr), .b_rdata(b_rdata),
        .busy(busy), .done(done), .c_flat(c_flat)
    );

    act_mem4 amem (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                   .raddr(a_raddr), .rdata(a_rdata));
    wrom4    wrom (.clk(clk), .raddr(b_raddr), .rdata(b_rdata));

    // ---- test data ----
    reg [7:0]  act_tmp [0:4095];
    reg [31:0] exp_mem [0:MAXT*16-1];
    reg [3:0]  lay_mem [0:MAXT-1];
    reg [9:0]  pos_mem [0:MAXT-1];
    reg [4:0]  py_mem  [0:MAXT-1];
    reg [4:0]  px_mem  [0:MAXT-1];
    reg [4:0]  ob_mem  [0:MAXT-1];

    reg [31:0] v [0:20];
    integer fd, r, ntiles, i, k, t, errors, bad_tiles, timeout, layer, obase;

    initial begin
        errors = 0; bad_tiles = 0; ntiles = 0;
        rst = 1'b1; start = 1'b0; we = 1'b0; waddr = 0; wdata = 0;
        cfg_fc = 0; cfg_K = 0; cfg_W = 0; cfg_HW = 0; cfg_OW = 0; cfg_npos = 0;
        cfg_abase = 0; cfg_wbase = 0; cfg_zp = -8'sd128; pos0 = 0; py0 = 0; px0 = 0;

        // load the activation memory image through the write port
        $readmemh({DATA_DIR, "act_init.hex"}, act_tmp);
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        for (i = 0; i < NACT; i = i + 1) begin
            we <= 1'b1; waddr <= i; wdata <= act_tmp[i];
            @(posedge clk);
        end
        we <= 1'b0;
        @(posedge clk);

        // load tile vectors
        fd = $fopen({DATA_DIR, "tile_vectors.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tile_vectors.txt - run gen_tile_vectors.py first");
            $finish;
        end
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                        v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10],
                        v[11], v[12], v[13], v[14], v[15], v[16], v[17], v[18], v[19], v[20]);
            if (r == 21) begin
                lay_mem[ntiles] = v[0]; pos_mem[ntiles] = v[1];
                py_mem[ntiles]  = v[2]; px_mem[ntiles]  = v[3]; ob_mem[ntiles] = v[4];
                for (k = 0; k < 16; k = k + 1) exp_mem[ntiles*16 + k] = v[5 + k];
                ntiles = ntiles + 1;
            end
        end
        $fclose(fd);
        $display("loaded %0d tiles", ntiles);

        for (t = 0; t < ntiles; t = t + 1) begin
            layer = lay_mem[t];
            obase = ob_mem[t];
            // layer configuration (must match gen_tile_vectors.py / wrom4.v layout)
            case (layer)
                0: begin cfg_fc <= 0; cfg_K <= 9;   cfg_W <= 28; cfg_HW <= 784; cfg_OW <= 26;
                         cfg_npos <= 676; cfg_abase <= 0;
                         cfg_wbase <= 0   + (obase/4) * 9;   end
                1: begin cfg_fc <= 0; cfg_K <= 72;  cfg_W <= 13; cfg_HW <= 169; cfg_OW <= 11;
                         cfg_npos <= 121; cfg_abase <= 784;
                         cfg_wbase <= 18  + (obase/4) * 72;  end
                default: begin
                         cfg_fc <= 1; cfg_K <= 400; cfg_W <= 0;  cfg_HW <= 0;   cfg_OW <= 0;
                         cfg_npos <= 4;   cfg_abase <= 2136;
                         cfg_wbase <= 306 + (obase/4) * 400; end
            endcase
            pos0 <= pos_mem[t]; py0 <= py_mem[t]; px0 <= px_mem[t];
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1;                          // let the engine clear its old `done` first

            timeout = 0;
            while (!done && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            #1;
            if (!done) begin
                $display("TIMEOUT on tile %0d", t);
                errors = errors + 1;
            end else begin
                k = 0;
                for (i = 0; i < 16; i = i + 1)
                    if (c_flat[i*32 +: 32] !== exp_mem[t*16 + i]) k = k + 1;
                if (k != 0) begin
                    errors = errors + k;
                    bad_tiles = bad_tiles + 1;
                    if (bad_tiles <= 5) begin
                        $display("MISMATCH tile %0d (layer %0d pos0 %0d obase %0d): %0d of 16 sums wrong",
                                 t, layer, pos_mem[t], obase, k);
                        for (i = 0; i < 16; i = i + 1)
                            if (c_flat[i*32 +: 32] !== exp_mem[t*16 + i])
                                $display("   C[%0d][%0d]: hw=%0d expected=%0d", i/4, i%4,
                                         $signed(c_flat[i*32 +: 32]), $signed(exp_mem[t*16 + i]));
                    end
                end
            end
            repeat (2) @(posedge clk);
        end

        $display("");
        $display("tiles: %0d, bad tiles: %0d, wrong sums: %0d", ntiles, bad_tiles, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
