module SystolicArrayMod (Clk, Rst, A_row0, A_row1, A_row2, A_row3, B_col0, B_col1, B_col2, B_col3, 
C_00, C_01, C_02, C_03, C_10, C_11, C_12, C_13, C_20, C_21, C_22, C_23, C_30, C_31, C_32, C_33);


parameter DATA_WIDTH = 16;
parameter ACC_WIDTH  = 32;


parameter ROW = 4;  // Number of rows in the systolic array
parameter COL = 4;  // Number of columns in the systolic array


input wire Clk, Rst;
input wire signed [DATA_WIDTH-1:0] A_row0, A_row1, A_row2, A_row3, B_col0, B_col1, B_col2, B_col3;
output wire signed [ACC_WIDTH-1:0] C_00, C_01, C_02, C_03, C_10, C_11, C_12, C_13, C_20, C_21, C_22, C_23, C_30, C_31, C_32, C_33;


wire signed [DATA_WIDTH-1:0] A[0:(ROW-1)][0:COL];
wire signed [DATA_WIDTH-1:0] B[0:ROW][0:(COL-1)];
wire signed [ACC_WIDTH-1:0] C[0:(ROW-1)][0:(COL-1)];

assign A[0][0] = A_row0;
assign A[1][0] = A_row1;
assign A[2][0] = A_row2;
assign A[3][0] = A_row3;


assign B[0][0] = B_col0;
assign B[0][1] = B_col1;
assign B[0][2] = B_col2;
assign B[0][3] = B_col3;


assign C_00 = C[0][0];
assign C_01 = C[0][1];
assign C_02 = C[0][2];
assign C_03 = C[0][3];

assign C_10 = C[1][0];
assign C_11 = C[1][1];
assign C_12 = C[1][2];
assign C_13 = C[1][3];


assign C_20 = C[2][0];
assign C_21 = C[2][1];
assign C_22 = C[2][2];
assign C_23 = C[2][3];


assign C_30 = C[3][0];
assign C_31 = C[3][1];
assign C_32 = C[3][2];
assign C_33 = C[3][3];



	
genvar r, c;
generate

for (r=0; r<ROW; r=r+1) 
begin: genrow
	for (c=0; c<COL; c=c+1)
	begin: gencol
	PE PE_inst(
	.clk (Clk),
	.rst (Rst),
	.a_in (A[r][c]),
	.b_in (B[r][c]),
	.a_out(A[r][c+1]),
	.b_out(B[r+1][c]),
	.c_out(C[r][c]));
	end
end





endgenerate

endmodule
