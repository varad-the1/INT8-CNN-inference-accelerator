`timescale 1ns/1ps

// Runs pool_seq on the conv1 and conv2 outputs from Python and compares every
// pooled value (in all four copies of the activation memory) with the reference.

module tb_pool_seq;

    localparam DATA_DIR = "data/";

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst, go;
    wire busy, done;
    reg  [13:0] cfg_src_base;
    reg  [11:0] cfg_dst_base;
    reg  [4:0]  cfg_in_n, cfg_out_n, cfg_ch;

    wire [13:0] r_addr;
    wire signed [7:0] r_data;
    wire        o_we;
    wire [11:0] o_addr;
    wire signed [7:0] o_data;

    pool_seq dut (
        .clk(clk), .rst(rst), .go(go), .busy(busy), .done(done),
        .cfg_src_base(cfg_src_base), .cfg_dst_base(cfg_dst_base),
        .cfg_in_n(cfg_in_n), .cfg_out_n(cfg_out_n), .cfg_ch(cfg_ch),
        .r_addr(r_addr), .r_data(r_data),
        .o_we(o_we), .o_addr(o_addr), .o_data(o_data)
    );

    // source: conv outputs, destination: the four-copy activation memory
    out_ram  src (.clk(clk), .we(1'b0), .waddr(14'd0), .wdata(8'sd0),
                  .raddr(r_addr), .rdata(r_data));
    act_mem4 dst (.clk(clk), .we(o_we), .waddr(o_addr), .wdata(o_data),
                  .raddr(48'd0), .rdata());

    reg [7:0] e1 [0:8191];
    reg [7:0] e2 [0:8191];
    reg [7:0] ep [0:8191];

    integer i, errors, layer_errors, t0, t1, shown;

    task check(input [8*16-1:0] name, input integer base, input integer n);
        begin
            layer_errors = 0; shown = 0;
            for (i = 0; i < n; i = i + 1)
                if (dst.m0[base+i] !== ep[i] || dst.m1[base+i] !== ep[i] ||
                    dst.m2[base+i] !== ep[i] || dst.m3[base+i] !== ep[i]) begin
                    layer_errors = layer_errors + 1;
                    if (shown < 5) begin
                        $display("   MISMATCH at %0d: hw=%0d expected=%0d", i,
                                 $signed(dst.m0[base+i]), $signed(ep[i]));
                        shown = shown + 1;
                    end
                end
            errors = errors + layer_errors;
            $display("%0s: %0d values, %0d wrong, %0d clocks", name, n, layer_errors, (t1 - t0) / 10);
        end
    endtask

    task run_pool;
        begin
            @(posedge clk);
            go <= 1'b1;
            t0 = $time;
            @(posedge clk);
            go <= 1'b0;
            #1;
            while (!done) @(posedge clk);
            t1 = $time;
            #1;
        end
    endtask

    initial begin
        errors = 0;
        rst = 1'b1; go = 1'b0;
        $readmemh({DATA_DIR, "expect_conv1.hex"}, e1);
        $readmemh({DATA_DIR, "expect_conv2.hex"}, e2);
        for (i = 0; i < 5408; i = i + 1) src.mem[i]        = e1[i];
        for (i = 0; i < 1936; i = i + 1) src.mem[5408 + i] = e2[i];
        for (i = 0; i < 4096; i = i + 1) begin
            dst.m0[i] = 8'h55; dst.m1[i] = 8'h55; dst.m2[i] = 8'h55; dst.m3[i] = 8'h55;
        end
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // pool1: 8 x 26 x 26 -> 8 x 13 x 13, written at 784
        cfg_src_base = 0;  cfg_dst_base = 784;  cfg_in_n = 26; cfg_out_n = 13; cfg_ch = 8;
        $readmemh({DATA_DIR, "expect_pool1.hex"}, ep);
        run_pool;
        check("pool1", 784, 8*13*13);

        // pool2: 16 x 11 x 11 -> 16 x 5 x 5, written at 2136
        cfg_src_base = 5408; cfg_dst_base = 2136; cfg_in_n = 11; cfg_out_n = 5; cfg_ch = 16;
        $readmemh({DATA_DIR, "expect_pool2.hex"}, ep);
        run_pool;
        check("pool2", 2136, 16*5*5);

        $display("");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d wrong values)", errors);
        $finish;
    end

endmodule
