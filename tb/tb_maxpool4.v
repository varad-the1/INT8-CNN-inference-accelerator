`timescale 1ns/1ps

// Checks maxpool4.v against reference/gen_pool_argmax_vectors.py.
// One window goes in per clock; results are compared in order, 1 clock later.

module tb_maxpool4;

    localparam DATA_DIR = "data/";
    localparam MAXV     = 20000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg signed [7:0] a_mem [0:MAXV-1];
    reg signed [7:0] b_mem [0:MAXV-1];
    reg signed [7:0] c_mem [0:MAXV-1];
    reg signed [7:0] d_mem [0:MAXV-1];
    reg signed [7:0] e_mem [0:MAXV-1];

    reg [7:0] t0, t1, t2, t3, t4;
    integer fd, r, nvec;

    reg               valid_in;
    reg signed [7:0]  a, b, c, d;
    wire              valid_out;
    wire signed [7:0] y;

    maxpool4 dut (.clk(clk), .valid_in(valid_in), .a(a), .b(b), .c(c), .d(d),
                  .valid_out(valid_out), .y(y));

    integer i, oi, errors;

    always @(posedge clk) begin
        if (valid_out) begin
            if (y !== e_mem[oi]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH #%0d: in=%0d %0d %0d %0d  hw=%0d expected=%0d",
                             oi, a_mem[oi], b_mem[oi], c_mem[oi], d_mem[oi], y, e_mem[oi]);
            end
            oi = oi + 1;
        end
    end

    initial begin
        errors = 0; oi = 0; nvec = 0;
        valid_in = 1'b0; a = 0; b = 0; c = 0; d = 0;

        fd = $fopen({DATA_DIR, "maxpool_vectors.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open maxpool_vectors.txt - run gen_pool_argmax_vectors.py first");
            $finish;
        end
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h\n", t0, t1, t2, t3, t4);
            if (r == 5) begin
                a_mem[nvec] = t0; b_mem[nvec] = t1; c_mem[nvec] = t2;
                d_mem[nvec] = t3; e_mem[nvec] = t4;
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("loaded %0d vectors", nvec);

        repeat (3) @(posedge clk);
        for (i = 0; i < nvec; i = i + 1) begin
            a <= a_mem[i]; b <= b_mem[i]; c <= c_mem[i]; d <= d_mem[i];
            valid_in <= 1'b1;
            @(posedge clk);
        end
        valid_in <= 1'b0;
        repeat (4) @(posedge clk);

        $display("");
        $display("checked %0d of %0d results, %0d mismatches", oi, nvec, errors);
        if (errors == 0 && oi == nvec) $display("RESULT: PASS");
        else                           $display("RESULT: FAIL");
        $finish;
    end

endmodule
