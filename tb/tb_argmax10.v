`timescale 1ns/1ps

// Checks argmax10.v against reference/gen_pool_argmax_vectors.py.
// Each vector is 10 scores sent on 10 consecutive clocks, with `last` on the
// 10th. Vectors follow each other back to back.

module tb_argmax10;

    localparam DATA_DIR = "data/";
    localparam MAXV     = 10000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg signed [7:0] s_mem [0:MAXV*10-1];   // scores, 10 per vector
    reg        [3:0] e_mem [0:MAXV-1];      // expected digit

    reg [7:0] t [0:10];
    integer fd, r, nvec;

    reg               rst, valid_in, last;
    reg signed [7:0]  score;
    wire              done;
    wire        [3:0] digit;

    argmax10 dut (.clk(clk), .rst(rst), .valid_in(valid_in), .score(score),
                  .last(last), .done(done), .digit(digit));

    integer i, k, oi, errors;

    always @(posedge clk) begin
        if (done) begin
            if (digit !== e_mem[oi]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH #%0d: hw=%0d expected=%0d  scores=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                             oi, digit, e_mem[oi],
                             s_mem[oi*10+0], s_mem[oi*10+1], s_mem[oi*10+2], s_mem[oi*10+3], s_mem[oi*10+4],
                             s_mem[oi*10+5], s_mem[oi*10+6], s_mem[oi*10+7], s_mem[oi*10+8], s_mem[oi*10+9]);
            end
            oi = oi + 1;
        end
    end

    initial begin
        errors = 0; oi = 0; nvec = 0;
        rst = 1'b1; valid_in = 1'b0; last = 1'b0; score = 0;

        fd = $fopen({DATA_DIR, "argmax_vectors.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open argmax_vectors.txt - run gen_pool_argmax_vectors.py first");
            $finish;
        end
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h\n",
                        t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10]);
            if (r == 11) begin
                for (k = 0; k < 10; k = k + 1) s_mem[nvec*10 + k] = t[k];
                e_mem[nvec] = t[10][3:0];
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("loaded %0d vectors", nvec);

        repeat (3) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        for (i = 0; i < nvec; i = i + 1) begin
            for (k = 0; k < 10; k = k + 1) begin
                score    <= s_mem[i*10 + k];
                valid_in <= 1'b1;
                last     <= (k == 9);
                @(posedge clk);
            end
        end
        valid_in <= 1'b0;
        last     <= 1'b0;
        repeat (4) @(posedge clk);

        $display("");
        $display("checked %0d of %0d results, %0d mismatches", oi, nvec, errors);
        if (errors == 0 && oi == nvec) $display("RESULT: PASS");
        else                           $display("RESULT: FAIL");
        $finish;
    end

endmodule
