`timescale 1ns/1ps

// Full-network test: for each of the 20 samples, load the image through the
// load port, pulse start, wait for done, and check
//   * the predicted digit against the label,
//   * all 10 logits (read from the logit memory) against ref_logits.hex.
// Prints the clock count of the whole inference.

module tb_cnn_top;

    localparam DATA_DIR = "data/";
    localparam N_TESTS  = 20;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst, start;
    wire busy, done;
    wire [3:0] digit;
    wire [31:0] cycles;
    reg load_we;
    reg [9:0] load_addr;
    reg signed [7:0] load_data;

    cnn_top dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .digit(digit), .cycles(cycles),
        .load_we(load_we), .load_addr(load_addr), .load_data(load_data)
    );

    reg [15:0] image_mem  [0:N_TESTS*784-1];
    reg [15:0] label_mem  [0:N_TESTS-1];
    reg [15:0] ref_mem    [0:N_TESTS*10-1];

    integer t, i, k, correct, logit_bad, samples_bad, last_cycles;

    initial begin
        correct = 0; logit_bad = 0; samples_bad = 0;
        rst = 1'b1; start = 1'b0; load_we = 1'b0; load_addr = 0; load_data = 0;
        $readmemh({DATA_DIR, "image.hex"},       image_mem);
        $readmemh({DATA_DIR, "test_labels.hex"}, label_mem);
        $readmemh({DATA_DIR, "ref_logits.hex"},  ref_mem);
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        for (t = 0; t < N_TESTS; t = t + 1) begin
            // load the image
            for (i = 0; i < 784; i = i + 1) begin
                load_we <= 1'b1; load_addr <= i; load_data <= image_mem[t*784 + i][7:0];
                @(posedge clk);
            end
            load_we <= 1'b0;
            @(posedge clk);

            // run
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1;
            while (!done) @(posedge clk);
            #1;
            last_cycles = cycles;

            // check logits
            k = 0;
            for (i = 0; i < 10; i = i + 1)
                if (dut.outm.mem[7344 + i] !== ref_mem[t*10 + i][7:0]) k = k + 1;
            logit_bad = logit_bad + k;
            if (k != 0) samples_bad = samples_bad + 1;

            if (digit == label_mem[t][3:0]) correct = correct + 1;
            $display("sample %2d: digit=%0d label=%0d  logits %s  %0d clocks",
                     t, digit, label_mem[t][3:0], (k == 0) ? "match" : "MISMATCH", last_cycles);
        end

        $display("");
        $display("==============================================");
        $display("accuracy: %0d/%0d", correct, N_TESTS);
        $display("samples with wrong logits: %0d", samples_bad);
        $display("clocks per inference: %0d  (%0d ns at 100 MHz)", last_cycles, last_cycles * 10);
        $display("==============================================");
        if (correct == N_TESTS && samples_bad == 0) $display("RESULT: PASS");
        else                                        $display("RESULT: FAIL");
        $finish;
    end

endmodule
