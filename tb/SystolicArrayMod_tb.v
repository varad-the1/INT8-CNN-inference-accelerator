// -----------------------------------------------------------------------
// tb_systolic_array.v - Testbench for systolic_array (plain Verilog)
//
// 1. Generates random 4x4 matrices A, B (8-bit values, so products/sums
//    comfortably fit the 32-bit accumulator).
// 2. Computes the "golden" C = A x B directly with ordinary nested-loop
//    multiplication (no DUT involved) -> C_golden.
// 3. Feeds A and B into the systolic array using the skewed schedule:
//
//        Cycle          1    2    3    4    5    6    7     8    9   10
//        A row 0:      a00  a01  a02  a03   0    0    0     0    0    0 
//        A row 1:       0   a10  a11  a12  a13   0    0     0    0    0
//        A row 2:       0    0   a20  a21  a22  a23   0     0    0    0
//        A row 3:       0    0    0   a30  a31  a32  a33    0    0    0
//
//        Cycle          1    2    3    4    5    6    7     8    9    10
//        B col 0:      b00  b10  b20  b30   0    0    0     0    0     0
//        B col 1:       0   b01  b11  b21  b31   0    0     0    0     0
//        B col 2:       0    0   b02  b12  b22  b32   0     0    0     0
//        B col 3:       0    0    0   b03  b13  b23  b33    0    0     0
//
// 4. Lets the pipeline drain, reads c_out_flat -> C_dut, and compares
//    C_dut against C_golden element by element.
// -----------------------------------------------------------------------
`timescale 1ns/1ps

module SystolicArrayMod_tb();

    parameter DATA_WIDTH = 16;
    parameter ACC_WIDTH  = 32;
    parameter ROW          = 4; //number of rows of first matrix
	 parameter COL          = 4; //number of rows of second matrix
	 parameter Length = 4; // number of rows of second matrix = number of columns of first matrix = Length
    parameter CLK_PERIOD = 10;
	 
	 wire signed [ACC_WIDTH-1:0] C_dut [0:(ROW-1)][0:(COL-1)];
	 reg signed [DATA_WIDTH-1:0] A_row_test[0:(ROW-1)];
	 reg signed [DATA_WIDTH-1:0] B_col_test[0:(COL-1)];

    reg                          clk_test;
    reg                          reset_test;

	 
	 



    // matrices: 0-indexed [row][col], row/col = 0..3
    integer A        [0:(ROW-1)][0:(Length-1)];
    integer B        [0:(Length-1)][0:COL-1];
    integer C_golden [0:(ROW-1)][0:(COL-1)];
  

    integer r, c, k, t, col_idx, row_idx;
    integer errors;
	 integer my_seed; //seed value for random number generation

    // ---------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------
    SystolicArrayMod dut (
        .Clk        (clk_test),
        .Rst      (reset_test),
        .A_row0  (A_row_test[0]),
		  .A_row1  (A_row_test[1]),
		  .A_row2  (A_row_test[2]),
		  .A_row3  (A_row_test[3]),
		  .B_col0  (B_col_test[0]),
		  .B_col1  (B_col_test[1]),
		  .B_col2  (B_col_test[2]),
		  .B_col3  (B_col_test[3]),
        .C_00 (C_dut[0][0]), .C_01 (C_dut[0][1]) , .C_02 (C_dut[0][2]), .C_03 (C_dut[0][3]),
		  .C_10 (C_dut[1][0]), .C_11 (C_dut[1][1]), .C_12 (C_dut[1][2]), .C_13 (C_dut[1][3]), 
		  .C_20 (C_dut[2][0]), .C_21 (C_dut[2][1]) , .C_22 (C_dut[2][2]), .C_23 (C_dut[2][3]),
		  .C_30 (C_dut[3][0]), .C_31 (C_dut[3][1]), .C_32 (C_dut[3][2]), .C_33 (C_dut[3][3])
    );

//	initial begin
//    $wlfall; // Tells ModelSim: "Log every single variable automatically"
//   end

	 
	always
	begin
		clk_test = 1'b0;
		#(CLK_PERIOD/2);
		clk_test = 1'b1;
		#(CLK_PERIOD/2);
	end
	
    // ---------------------------------------------------------------
    // stimulus + checking
    // ---------------------------------------------------------------
    initial begin
        // -- init / reset -------------------------------------------------
        reset_test     = 1'b1;
		  
        A_row_test[0] = {1*DATA_WIDTH{1'b0}};
		  A_row_test[1] = {1*DATA_WIDTH{1'b0}};
		  A_row_test[2] = {1*DATA_WIDTH{1'b0}};
		  A_row_test[3] = {1*DATA_WIDTH{1'b0}};
		  
		  B_col_test[0] = {1*DATA_WIDTH{1'b0}};
		  B_col_test[1] = {1*DATA_WIDTH{1'b0}};
		  B_col_test[2] = {1*DATA_WIDTH{1'b0}};
		  B_col_test[3] = {1*DATA_WIDTH{1'b0}};
		  

        errors    = 0;
		  my_seed = 3;

        repeat (2) @(negedge clk_test);
        reset_test = 1'b0;

        // -- random 8-bit A, B (keeps 4-term sums well inside 32 bits) ----
		  
        for (r = 0; r < ROW; r = r + 1) begin
            for (c = 0; c < Length; c = c + 1) begin
                A[r][c] = ($random(my_seed)) & 32'h0000_00FF;
            end
        end
		  
		  for (r = 0; r < Length; r = r + 1) begin
            for (c = 0; c < COL; c = c + 1) begin
                B[r][c] = ($random(my_seed)) & 32'h0000_00FF;
            end
        end

        $display("---- Matrix A ----");
        for (r = 0; r < ROW; r = r + 1)
            $display("%3d %3d %3d %3d", A[r][0], A[r][1], A[r][2], A[r][3]);

        $display("---- Matrix B ----");
        for (r = 0; r < Length; r = r + 1)
            $display("%3d %3d %3d %3d", B[r][0], B[r][1], B[r][2], B[r][3]);

        // -- golden result: plain triple-loop multiplication --------------
        for (r = 0; r < ROW; r = r + 1) begin
            for (c = 0; c < COL; c = c + 1) begin
                C_golden[r][c] = 0;
                for (k = 0; k < Length; k = k + 1)
                    C_golden[r][c] = C_golden[r][c] + A[r][k]*B[k][c];
            end
        end

        // -- drive the skewed schedule, cycles t = 1..7 --------------------
        for (t = 0; t < ((2*(ROW-1))+ Length); t = t + 1) 
		  begin
            @(negedge clk_test);
				
				begin

            for (r = 0; r < ROW; r = r + 1) 
				begin
                col_idx = t - r;              // which A column is on row r this cycle
                if (col_idx >= 0 && col_idx < COL)
                    A_row_test[r] = A[r][col_idx];
					 else
						  A_row_test[r] = {1*DATA_WIDTH{1'b0}};
            end

            for (c = 0; c < COL; c = c + 1) 
				begin
                row_idx = t - c;              // which B row is on col c this cycle
                if (row_idx >= 0 && row_idx < ROW)
                    B_col_test[c] = B[row_idx][c];
					 else
						  B_col_test[c] = {1*DATA_WIDTH{1'b0}};
            end
				
				end
				
        end

        // -- stop feeding, let the pipeline drain --------------------------
        @(negedge clk_test);
		  
		  begin
       
        A_row_test[0] = {1*DATA_WIDTH{1'b0}};
		  A_row_test[1] = {1*DATA_WIDTH{1'b0}};
		  A_row_test[2] = {1*DATA_WIDTH{1'b0}};
		  A_row_test[3] = {1*DATA_WIDTH{1'b0}};
		  
		  B_col_test[0] = {1*DATA_WIDTH{1'b0}};
		  B_col_test[1] = {1*DATA_WIDTH{1'b0}};
		  B_col_test[2] = {1*DATA_WIDTH{1'b0}};
		  B_col_test[3] = {1*DATA_WIDTH{1'b0}};
		  
		  end

        repeat (2) @(negedge clk_test);
        reset_test = 1'b0;

        // -- unpack DUT result and compare ---------------------------------
        $display("---- Comparing systolic array output to golden C = A x B ----");
        for (r = 0; r < ROW; r = r + 1) begin
            for (c = 0; c < COL; c = c + 1) begin
                if (C_dut[r][c] !== C_golden[r][c]) begin
                    errors = errors + 1;
                    $display("MISMATCH C[%0d][%0d]: dut=%0d golden=%0d",
                              r, c, C_dut[r][c], C_golden[r][c]);
                end else begin
                    $display("match    C[%0d][%0d]: dut=%0d golden=%0d",
                              r, c, C_dut[r][c], C_golden[r][c]);
                end
            end
        end

        if (errors == 0)
            $display("*** PASS: all 16 elements match ***\n");
        else
            $display("*** FAIL: %0d mismatching elements ***\n", errors);

        $stop;
    end

endmodule