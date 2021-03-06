parameter DW = 16;
parameter AW = 8;

module pllclk (input ext_clock, output pll_clock, input nrst, output lock);
   wire dummy_out;
   wire bypass, lock1;

   assign bypass = 1'b0;

   SB_PLL40_CORE #(.FEEDBACK_PATH("SIMPLE"), .PLLOUT_SELECT("GENCLK"),
		   .DIVR(4'd0), .DIVF(7'b1000111), .DIVQ(3'b011),
		   .FILTER_RANGE(3'b001)
   ) mypll1 (.REFERENCECLK(ext_clock),
	    .PLLOUTGLOBAL(pll_clock), .PLLOUTCORE(dummy_out), .LOCK(lock1),
	    .RESETB(nrst), .BYPASS(bypass));

endmodule	    


module dff #(parameter W=1)
   (input wire[W-1:0] D, input clk, output reg[W-1:0] Q);

   always @(posedge clk)
     Q <= D;
endmodule // dff


module synchroniser #(parameter W=1)
   (input wire[W-1:0] D, input clk, output wire[W-1:0] Q);

   wire[W-1:0] M;

   dff #(W) first_reg(D, clk, M);
   dff #(W) last_reg(M, clk, Q);
endmodule


module edge_detector(input async_signal, input clk, output reg edge_detected);
   wire sync_signal;
   wire last_signal;

   synchroniser syncer(async_signal, clk, sync_signal);
   dff save_last(sync_signal, clk, last_signal);

   always @(posedge clk)
     edge_detected <= sync_signal ^ last_signal;
endmodule // edge_detector


module posedge_detector(input async_signal, input clk, output reg edge_detected);
   wire sync_signal;
   wire last_signal;

   synchroniser syncer(async_signal, clk, sync_signal);
   dff save_last(sync_signal, clk, last_signal);

   always @(posedge clk)
     edge_detected <= sync_signal & ~last_signal;
endmodule // posedge_detector


module posedge_counter #(parameter W=8)
   (input async_signal, input clk, output wire[W-1:0] count);

   wire gotedge;
   reg[W-1:0] counter;

   posedge_detector detector(async_signal, clk, gotedge);

   always @(posedge clk)
     if (gotedge)
       counter <= counter+1;

   assign count = counter;
endmodule // posedge_counter


module count_pulses_on_leds(input async_pulse_pin, clk, output wire[7:0] leds);
   wire[7:0] pulse_count;

   posedge_counter #(8) mycounter(async_pulse_pin, clk, pulse_count);
   assign leds = pulse_count;
endmodule // count_pulses_on_leds 

module clocked_bus_slave #(parameter ADRW=1, DATW=1)
  (input aNE, aNOE, aNWE,
   input wire [ADRW-1:0] aAn, input wire[DATW-1:0] aDn,
   input 		 clk,
   output wire[ADRW-1:0] r_adr, output wire[ADRW-1:0] w_adr,
   output reg 		 do_read, input wire[DATW-1:0] read_data,
   output reg 		 do_write, output reg[DATW-1:0] w_data,
   output 		 io_output, output wire[DATW-1:0] io_data);

   wire sNE, sNOE, sNWE;
   reg[ADRW-1:0] sAn_r;
   reg[ADRW-1:0] sAn_w;
   reg[DATW-1:0] rDn;
   reg[DATW-1:0] wDn;
   wire[ADRW-1:0] next_sAn_r;
   wire[ADRW-1:0] next_sAn_w;
   wire[DATW-1:0] next_rDn;
   wire[DATW-1:0] next_wDn;
   wire next_do_write, next_do_read;

   // States for one-hot state machine.
   reg st_idle=1, st_write=0, st_read1=0, st_read2=0;
   wire next_st_idle, next_st_write, next_st_read1, next_st_read2;

   synchroniser sync_NE(aNE, clk, sNE);
   synchroniser sync_NOE(aNOE, clk, sNOE);
   synchroniser sync_NWE(aNWE, clk, sNWE);

   always @(posedge clk) begin
      st_idle <= next_st_idle;
      st_write <= next_st_write;
      st_read1 <= next_st_read1;
      st_read2 <= next_st_read2;

      do_write <= next_do_write;
      do_read <= next_do_read;

      sAn_r <= next_sAn_r;
      sAn_w <= next_sAn_w;
      wDn <= next_wDn;
      rDn <= next_rDn;
   end

   /* Latch the address on the falling edge of NOE (read) or NWE (write).
      We can use the external address unsynchronised, as it will be stable
      when NOE/NWE toggles.
    */
   assign next_sAn_r = st_idle & ~sNE & ~sNOE ? aAn : sAn_r;
   assign next_sAn_w = st_idle & ~sNE & ~sNWE ? aAn : sAn_w;

   /* Incoming write. */
   /* Latch the write data on the falling edge of NWE. NWE is synchronised,
      so the synchronisation delay is enough to ensure that the async external
      data signal is stable at this point.
    */
   assign next_wDn = st_idle & ~sNE & ~sNWE ? aDn : wDn;
   // Trigger a register write when NWE goes low.
   assign next_do_write = st_idle & ~sNE & ~sNWE;
   assign next_st_write = (st_idle | st_write) & (~sNE & ~sNWE);

   /* Incoming read. */
   assign next_do_read = st_idle & ~sNE & ~sNOE;
   /* Wait one cycle for register read data to become available. */
   assign next_st_read1 = st_idle & ~sNE & ~sNOE;
   /* Put read data on the bus while NOE is asserted. */
   assign next_st_read2 = (st_read1 | st_read2) & ~sNE & ~sNOE;

   assign next_st_idle = ((st_read1 | st_read2) & (sNOE | sNE)) |
			 (st_write & (sNWE | sNE)) |
			 (st_idle & (sNE | (sNOE & sNWE)));

   /* Latch register read data one cycle after asserting do_read. */
   assign next_rDn = st_read1 ? read_data : rDn;
   /* Output data during read after latching read data. */
   assign io_output = st_read2 & next_st_read2;
   assign io_data = rDn;

   assign r_adr = sAn_r;
   assign w_adr = sAn_w;
   assign w_data = wDn;
endmodule // clocked_bus_slave


module writable_regs(input do_write, input wire[AW-1:0] w_adr,
		     input wire[DW-1:0] w_data, input clk,
		     output wire[DW-1:0] v0, v1, v2, v3);
   reg[DW-1:0] vreg0, vreg1, vreg2, vreg3;

   always @(posedge clk) begin
      if (do_write) begin
	 case (w_adr)
	   8'd6: vreg0 <= w_data;
	   8'd100: vreg1 <= w_data;
	   8'd60: vreg2 <= w_data;
	   8'hff: vreg3 <= w_data;
	 endcase // case (w_adr)
      end
   end
   assign v0 = vreg0;
   assign v1 = vreg1;
   assign v2 = vreg2;
   assign v3 = vreg3;
endmodule // writable_regs
   

module error_counter(input wire clk, input wire enable,
		     input wire[DW-1:0] old_val, input wire[DW-1:0] new_val,
		     output wire [7:0] err_cnt);

   reg [DW-1:0] old_val1;
   reg [DW-1:0] new_val1;
   reg enable1;
   reg [DW-1:0] cmp_val2;
   reg [DW-1:0] new_val2;
   reg enable2;
   reg chk_err3;
   reg carry4;
   reg [3:0] low_cnt4 = 4'b0000;
   reg [7:4] high_cnt5 = 4'b0000;
   reg [3:0] low_cnt5;

   always @(posedge clk) begin
      // First pipeline stage, just buffer inputs.
      old_val1 <= old_val;
      new_val1 <= new_val;
      enable1 <= enable;

      // Second pipeline stage, compute compare value.
      cmp_val2 <= old_val1 + 1;
      new_val2 <= new_val1;
      enable2 <= enable1;

      // Third stage: Comparison.
      chk_err3 <= ((enable2 & (cmp_val2 != new_val2)) ? 1'b1 : 1'b0);

      // Fourth stage: Low error count increment.
      if (chk_err3) begin
	 carry4 <= ((low_cnt4 == 4'b1111) ? 1'b1 : 1'b0); low_cnt4 <= low_cnt4+1;
         //{ carry4, low_cnt4 } <= { 0, low_cnt4 } + 5'b00001;
      end else
	carry4 <= 0;

      // Fifth stage: Upper count increment.
      // Can only occur every 1/16 cycle at the most, so safe to use value from
      // two steps back in the pipeline.
      low_cnt5 <= low_cnt4;
      if (carry4)
	high_cnt5 <= high_cnt5 + 4'b0001;
   end // always @ (posedge clk)

   assign err_cnt = { high_cnt5, low_cnt5 };

endmodule // error_counter


module top (
	input crystal_clk,
	input STM32_PIN,
	input aNE, aNOE, aNWE,
	input [AW-1:0] aA,
	inout [DW-1:0] aD,
	output [7:0] LED,
	input uart_tx_in, output uart_tx_out
);

   wire clk;
   wire nrst, lock;
   wire [7:0] pulse_counter;
   wire[DW-1:0] aDn_output;
   wire[DW-1:0] aDn_input;
   wire io_d_output;
   wire do_write;
   wire[AW-1:0] r_adr;
   wire[AW-1:0] w_adr;
   wire[DW-1:0] w_data;
   wire do_read;
   wire[DW-1:0] register_data;
   reg[DW-1:0] leddata0, leddata1, leddata2, leddata3;
   wire chk_err;
   wire[7:0] err_count;

   /* Type 101001 is output with tristate/enable and simple input. */
   SB_IO #(.PIN_TYPE(6'b1010_01), .PULLUP(1'b0))
     io_Dn[DW-1:0](.PACKAGE_PIN(aD),
	   .OUTPUT_ENABLE(io_d_output),
	   .D_OUT_0(aDn_output),
	   .D_IN_0(aDn_input)
	   );

   assign nrst = 1'b1;
   pllclk my_pll(crystal_clk, clk, nrst, lock);
   count_pulses_on_leds my_ledshow(/*STM32_PIN*/aNWE, clk, pulse_counter);

   clocked_bus_slave #(.ADRW(AW), .DATW(DW))
     my_bus_slave(aNE, aNOE, aNWE,
		  aA, aDn_input,
		  clk, r_adr, w_adr,
		  do_read, register_data,
		  do_write, w_data,
		  io_d_output, aDn_output);

   writable_regs led_registers(do_write, w_adr, w_data, clk,
			       leddata0, leddata1, leddata2, leddata3);

   /* The clocked_bus_slave asserts do_read once per read transaction on the
      external bus (synchronous on clk). This can be used to have side effects
      on read (eg. clear "data ready" on read of data register). However, in
      this particular case we have no such side effects, so can just decode
      the read data continously (clocked_bus_slave latches the read value).
    */
   always @(*) begin
      case (r_adr)
	8'd6: register_data <= leddata0;
	8'd100: register_data <= leddata1;
	8'd60: register_data <= leddata2;
	8'hff: register_data <= leddata3;
	default: register_data <= 0;
      endcase // case (r_adr)
   end

   /*
   always @(posedge clk) begin
      if (do_read) begin
	 case (r_adr)
	   2'b00: leddata0 <= leddata0 + 1;
	   2'b01: leddata1 <= leddata1 + 1;
	   2'b10: leddata2 <= leddata2 + 1;
	   2'b11: leddata3 <= leddata3 + 1;
	 endcase // case (r_adr)
      end else if (do_write) begin
	 case (w_adr)
	   2'b00: begin
	      leddata0 <= w_data;
	   end
	   2'b01:
	     leddata1 <= w_data;
	   2'b10:
	     leddata2 <= w_data;
	   2'b11:
	     leddata3 <= w_data;
	 endcase // case (w_adr)
      end
   end

   assign chk_err = (do_write & rw_adr == 3'b000);
   error_counter my_errcnt0(clk, chk_err, leddata0, w_data, err_count);
   */

   /* For debugging, proxy an UART Tx signal to the FTDI chip. */
   assign uart_tx_out = uart_tx_in;
   
   assign LED[1:0] = pulse_counter[2:1];
   assign LED[2:4] = leddata0;
   assign LED[5:7] = leddata1;
   //assign {LED0, LED1, LED2, LED3, LED4, LED5, LED6, LED7} = err_count;
endmodule
