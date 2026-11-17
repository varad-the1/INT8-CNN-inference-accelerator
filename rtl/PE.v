module PE(clk, rst, a_in, b_in, a_out, b_out, c_out);

parameter DATA_WIDTH = 16;
parameter ACC_WIDTH  = 32;


input wire clk, rst;
input wire signed [DATA_WIDTH-1:0] a_in, b_in;
output reg signed [DATA_WIDTH-1:0] a_out, b_out;
output reg signed [ACC_WIDTH-1:0]  c_out;


always @(posedge clk, posedge rst) 
begin
        if (rst == 1'b1) 
		  begin
            a_out <= 0;
            b_out <= 0;
            c_out <= 0;
        end 
		  else
		  begin
            a_out <= a_in;
            b_out <= b_in;
            c_out <= c_out + (a_in * b_in);
        end
end

endmodule

