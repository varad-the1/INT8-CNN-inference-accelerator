`timescale 1ns/1ps

// Checks requantizer.v against vectors made by reference/gen_requant_vectors.py.
// One new vector goes in every clock; results are compared in order as they
// come out 3 clocks later.

module tb_requantizer;

    localparam DATA_DIR = "data/";
    localparam MAXV     = 40000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg signed [31:0] acc_mem [0:MAXV-1];
    reg signed [31:0] m0_mem  [0:MAXV-1];
    reg        [7:0]  sh_mem  [0:MAXV-1];
    reg signed [31:0] zp_mem  [0:MAXV-1];
    reg signed [7:0]  exp_mem [0:MAXV-1];

    reg signed [31:0] a_t, m_t, z_t;
    reg        [7:0]  s_t, e_t;
    integer fd, r, nvec;

    reg                valid_in;
    reg  signed [31:0] acc, m0, out_zp;
    reg         [4:0]  shift_r;
    wire               valid_out;
    wire signed [7:0]  result;

    requantizer dut (
        .clk      (clk),
        .valid_in (valid_in),
        .acc      (acc),
        .m0       (m0),
        .shift_r  (shift_r),
        .out_zp   (out_zp),
        .valid_out(valid_out),
        .result   (result)
    );

    integer i, oi, errors;

    // Compare each result as it comes out (sampled at the clock edge,
    // so it sees the value registered on the previous edge).
    always @(posedge clk) begin
        if (valid_out) begin
            if (result !== exp_mem[oi]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH #%0d: acc=%0d m0=%0d shift=%0d zp=%0d  hw=%0d expected=%0d",
                             oi, acc_mem[oi], m0_mem[oi], sh_mem[oi],
                             zp_mem[oi], result, exp_mem[oi]);
            end
            oi = oi + 1;
        end
    end

    initial begin
        errors = 0;
        oi     = 0;
        nvec   = 0;
        valid_in = 1'b0;
        acc = 0; m0 = 0; out_zp = 0; shift_r = 0;

        fd = $fopen({DATA_DIR, "requant_vectors.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open requant_vectors.txt - run gen_requant_vectors.py first");
            $finish;
        end
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h\n", a_t, m_t, s_t, z_t, e_t);
            if (r == 5) begin
                acc_mem[nvec] = a_t;
                m0_mem[nvec]  = m_t;
                sh_mem[nvec]  = s_t;
                zp_mem[nvec]  = z_t;
                exp_mem[nvec] = e_t;
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("loaded %0d vectors", nvec);

        repeat (3) @(posedge clk);

        for (i = 0; i < nvec; i = i + 1) begin
            acc      <= acc_mem[i];
            m0       <= m0_mem[i];
            shift_r  <= sh_mem[i][4:0];
            out_zp   <= zp_mem[i];
            valid_in <= 1'b1;
            @(posedge clk);
        end
        valid_in <= 1'b0;

        repeat (6) @(posedge clk);

        $display("");
        $display("checked %0d of %0d results, %0d mismatches", oi, nvec, errors);
        if (errors == 0 && oi == nvec)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
