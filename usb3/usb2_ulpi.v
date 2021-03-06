
//
// usb 2.0 ulpi
//
// Copyright (c) 2012-2013 Marshall H.
// All rights reserved.
// This code is released under the terms of the simplified BSD license. 
// See LICENSE.TXT for details.
//

module usb2_ulpi (

// top-level interface
input wire        clk_suspend, /* always "on" clk */
output	wire		suspend,
input wire        reset_n,
output   wire        reset_local,
input wire        opt_disable_all,
input wire        opt_enable_hs,
input wire        opt_ignore_vbus,
output   wire        stat_connected,
output   reg            stat_fs,
output   reg            stat_hs,

// ulpi usb phy connection
input wire        phy_clk,
input wire  [7:0] phy_d_in,
output   wire  [7:0] phy_d_out_mux,
output   wire        phy_d_oe,
input wire        phy_dir,
output   wire        phy_stp,
input wire        phy_nxt,

// connection to packet layer
output   wire        pkt_out_act,
output   wire  [7:0] pkt_out_byte,
output   wire        pkt_out_latch,

output   wire        pkt_in_cts,
output   wire        pkt_in_nxt,
input wire  [7:0] pkt_in_byte,
input wire        pkt_in_latch,
input wire        pkt_in_stp,

output   wire        se0_reset,

// debug signals
output   wire  [1:0] dbg_linestate

);


////////////////////////////////////////////////////////////////////
//
// 60mhz ulpi clock domain
//
////////////////////////////////////////////////////////////////////

   reg            reset_1, reset_2;
	reg		[15:0]	reset_waittime;
   reg            reset_ulpi;
   assign         reset_local = reset_n & reset_ulpi;
   reg            opt_enable_hs_1, opt_enable_hs_2;
   reg            opt_ignore_vbus_1, opt_ignore_vbus_2;
   reg            phy_dir_1;
   reg      [7:0] phy_d_out;
   reg      [7:0] phy_d_next;
   reg            phy_d_sel;
   assign   phy_d_out_mux  = phy_d_sel ? pkt_in_byte : phy_d_out;
   assign   phy_d_oe = !phy_dir_1;
   reg            phy_stp_out;
	reg				force_stp;
   assign         phy_stp        = (force_stp) ? 1 : phy_stp_out ^ pkt_in_stp;
   reg      [7:0] in_rx_cmd;
   reg            know_recv_packet;          // phy will drive NXT and DIR high
                                       // simultaneously to signify a receive
                                       // packet as opposed to normal RX_CMD
                                       // in any case the RX_CMD will reflect this 
                                       // just a bit later anyway
   reg      [1:0] last_line_state;
   wire  [1:0] line_state  = in_rx_cmd[1:0];
   wire  [1:0] vbus_state  = in_rx_cmd[3:2];
   wire  [1:0] rx_event = in_rx_cmd[5:4];
   //wire         id_gnd      = in_rx_cmd[6];
   //wire         alt_int     = in_rx_cmd[7];
   
   //wire         sess_end = (vbus_state == 2'b00);
   //wire         sess_valid  = (vbus_state == 2'b10);
   wire        vbus_valid  = (vbus_state == 2'b11);
   reg            vbus_valid_1; 
   assign         stat_connected = vbus_valid;  // in HS mode explicit bit-stuff error will
                                       // also signal EOP but this is Good Enough(tm)  
   wire        rx_active   = (rx_event[0]);
   //wire         rx_error = (rx_event == 2'b11);
   //wire         host_discon = (rx_event == 2'b10); // only valid in host mode  
   
   reg      [2:0] tx_cmd_code;               // ULPI TX_CMD code with extra bit
   reg      [7:0] tx_reg_addr;               // register address (6 and 8bit)
   reg      [7:0] tx_reg_data_rd;               // data read
   reg      [7:0] tx_reg_data_wr;               // data to write
   reg      [3:0] tx_pid;                    // packet ID for sending data
   parameter [2:0]   TX_CMD_XMIT_NOPID = 3'b001,   // two LSB are ULPI cmdcode
               TX_CMD_XMIT_PID      = 3'b101,   
               TX_CMD_REGWR_IMM  = 3'b010,
               TX_CMD_REGWR_EXT  = 3'b110,
               TX_CMD_REGRD_IMM  = 3'b011,
               TX_CMD_REGRD_EXT  = 3'b111;
   
   reg            can_send;
   reg      [3:0] can_send_delay;
   reg             [3:0] chirp_k_seen;
   reg             [3:0] chirp_j_seen;
   reg      [6:0] state;
   reg      [6:0] state_next;

  
   reg            pkt_in_latch_defer;
   parameter [6:0]   ST_RST_0       = 7'd0,
               ST_RST_1       = 7'd1,
               ST_RST_2       = 7'd2,
               ST_RST_3       = 7'd3,
               ST_RST_4       = 7'd4,
               ST_IDLE           = 7'd10,
               ST_RX_0           = 7'd20,
               ST_TXCMD_0        = 7'd30,
               ST_TXCMD_1        = 7'd31,
               ST_TXCMD_2        = 7'd32,
               ST_TXCMD_3        = 7'd33,
               ST_PKT_0       = 7'd40,
               ST_PKT_1       = 7'd41,
               ST_PKT_2       = 7'd42,
               ST_CHIRP_0        = 7'd50,
               ST_CHIRP_1        = 7'd51,
               ST_CHIRP_2        = 7'd52,
               ST_CHIRP_3        = 7'd53,
               ST_CHIRP_4        = 7'd54,
               ST_CHIRP_5        = 7'd55,
               ST_SUSPEND                      = 7'd56,
               ST_SUSPEND_ACT          = 7'd57,
               ST_SUSPEND_ACT2         = 7'd58,
               ST_SUSPEND_OR_RESET     = 7'd59,
               ST_SUSPEND_ACT3         = 7'd60,
	       ST_CHIRP_WAIT_KJKJKJ        = 7'd61;
					
   // mux local ULPI control with packet layer
   assign   pkt_out_latch  = pkt_out_act & phy_dir & phy_nxt;
   assign   pkt_out_byte   = pkt_out_latch ? phy_d_in : 8'h0;
   assign   pkt_out_act    = (rx_active | know_recv_packet) & phy_dir;
   
   assign   pkt_in_cts     = ~phy_dir & can_send;
   assign   pkt_in_nxt     = phy_nxt && (state == ST_PKT_1 || state == ST_PKT_2);
 
   reg      [7:0] dc;
   reg      [11:0]   dc_wrap;
   
   // about 3ms from start of SE0
   wire        se0_bus_reset  = (dc_wrap == 710); 
   assign         se0_reset      = se0_bus_reset;
   
   assign         dbg_linestate = line_state;
   
   // aospan: suspend/resume part
	reg	suspend_reset_1, suspend_reset_2;
   reg	resume;
	wire	resume_s;
	reg is_suspend;
	wire is_suspend_s;
	reg	phy_dir_prev;
   reg	[1:0] linestate_prev;
	reg	[3:0]   susp_state;
	
   parameter [3:0]   ST_SUSPEND_RST				= 4'd0,
							ST_SUSPEND_IDLE			= 4'd1,
                     ST_SUSPEND_WAKEUP			= 4'd2,
							ST_SUSPEND_WAIT_PHY		= 4'd3,
							ST_SUSPEND_WAIT_RESUME	= 4'd4;		
	
   
reg	[31:0] source;
reg	[31:0] probe;

/* 
`ifndef MODEL_TECH
probe   probe_inst(
        .probe( probe ),
        .source(source)
);
`endif
*/

synchronizer resume_ss (
	.clk (phy_clk),
	.async_in(resume),
	.sync_out(resume_s)
);

synchronizer is_suspend_ss (
	.clk (clk_suspend),
	.async_in(is_suspend),
	.sync_out(is_suspend_s)
);

assign suspend = is_suspend_s;

							
/* aospan: this block always works even phy_clk is disabled due to suspend mode 
* this block handle phy's "low power" (suspend) mode
*/
always @(posedge clk_suspend) begin
	linestate_prev <= phy_d_in[1:0];
	phy_dir_prev <= phy_dir;
	{suspend_reset_2, suspend_reset_1} <= {suspend_reset_1, reset_n};
	
	if(~suspend_reset_2) susp_state <= ST_SUSPEND_RST;
			
	case(susp_state)
		ST_SUSPEND_RST:
		begin
			force_stp <= 0;
			resume <= 0;
			phy_dir_prev <= 0;
			linestate_prev <= 0;
			susp_state <= ST_SUSPEND_IDLE;
		end
		
		ST_SUSPEND_IDLE:
		begin
			if ( is_suspend_s )
			begin
				/* now we are officially suspended */
				resume <= 0;
				susp_state <= ST_SUSPEND_WAIT_RESUME;
			end
		end
		
		ST_SUSPEND_WAIT_RESUME:
		begin
			// detect resume 
			// from usb 2.0 spec: If a device is in the Suspend state, its operation is 
			// resumed when any non-idle signaling is received on its upstream facing port.
			
			// monitor DM
			if (linestate_prev[1])
			begin
				susp_state <= ST_SUSPEND_WAKEUP;
				force_stp <= 1;
			end
		end
		
		ST_SUSPEND_WAKEUP:
		begin
			// USB3320 DS: After DIR has been de-asserted, the Link can de-assert   
			// STP when ready and start operating in Synchronous Mode
			if(~phy_dir_prev) 
			begin
				resume <= 1;
				force_stp <= 0;
				susp_state <= ST_SUSPEND_WAIT_PHY;
			end
		end
		
		ST_SUSPEND_WAIT_PHY:
		begin
			if (!is_suspend_s)
			begin
				resume <= 0; /* phy_clk appear, "resume" propagated. deassert it */
				susp_state <= ST_SUSPEND_IDLE;
			end
		end
		
		default: susp_state <= ST_SUSPEND_RST;
	endcase
end


always @(posedge phy_clk) begin
   // edge detection / synchronize
   {reset_2, reset_1} <= {reset_1, reset_n};
   {opt_enable_hs_2, opt_enable_hs_1} <= {opt_enable_hs_1, opt_enable_hs};
   {opt_ignore_vbus_2, opt_ignore_vbus_1} <= {opt_ignore_vbus_1, opt_ignore_vbus};
   
   vbus_valid_1 <= vbus_valid;
   phy_dir_1 <= phy_dir;
	
   dc <= dc + 1'b1;
	
   // clear to send (for packet layer) generation
   if(can_send) begin 
      if(can_send_delay < stat_hs ? 4'hF : 4'h0) 
         can_send_delay <= can_send_delay + 1'b1;
   end else begin
      can_send_delay <= 0;
   end
   
   // default state
   phy_stp_out <= 1'b0;
   // account for the turnaround cycle delay
   phy_d_out <= phy_d_next;
   // catch latches while receiving
   if(pkt_in_latch) pkt_in_latch_defer <= 1;
   
   // main fsm
   //
   case(state)
   ST_RST_0: begin
      // reset state
      phy_d_out <= 8'h0;
      phy_d_next <= 8'h0;
      phy_stp_out <= 1'b0;
      phy_dir_1 <= 1'b1;
      stat_fs <= 1'b0;
      stat_hs <= 1'b0;
      can_send <= 1'b0;
      vbus_valid_1 <= 1'b0;
      dc <= 0;
      dc_wrap <= 0;
      pkt_in_latch_defer <= 0;
      chirp_k_seen <= 0;
      chirp_j_seen <= 0;
		reset_waittime <= 2000; /* 10 ms */
		phy_d_sel <= 0; /* ulpi driving data lines */
		
      // stay stuck in reset, if disable is specified
      if(opt_disable_all) 
         state <= ST_RST_0;
      else
         state <= ST_RST_1;
   end
   ST_RST_1: begin
      // take other modules out of reset, whether initial or caused by 
      // usb cable disconnect
      reset_ulpi <= 1;
      // reset phy and set mode
      tx_cmd_code <=       TX_CMD_REGWR_IMM;
      tx_reg_addr <=       6'h4;
      tx_reg_data_wr <= {  2'b01,      // Resvd, SuspendM [disabled]
                     1'b1,       // Reset (auto-cleared by PHY)
                     2'b00,      // OpMode [normal]
                     1'b1,    // TermSelect [enable]
                     2'b01    // XcvrSel [full speed]
      };
      // wait 10ms for debounce on prior disconnect
      if(dc == 255) dc_wrap <= dc_wrap + 1'b1;
      if(~phy_dir & dc_wrap == reset_waittime) begin
         state <= ST_TXCMD_0; 
         state_next <= ST_RST_2;
      end
   end
   ST_RST_2: begin
      // wait for phy to begin reset
      // if times out, try again
      if(dc == 255) state <= ST_RST_0;
      if(phy_dir) state <= ST_RST_3;
   end
   ST_RST_3: begin
      // wait for next rising edge
      // then receive initial RX_CMD
      if(phy_dir) state <= ST_RX_0;
      state_next <= ST_RST_4;
   end
   ST_RST_4: begin
      // turn off OTG pulldowns and disable pullup
      // on ID pin (OTG would drive low if connected)
      tx_cmd_code <=       TX_CMD_REGWR_IMM;
      tx_reg_addr <=       6'hA;
      tx_reg_data_wr <=    8'h0;
      
      state <= ST_TXCMD_0;
      state_next <= ST_IDLE;
   end
   
   
   // idle dispatch
   //
   ST_IDLE: begin
      // increment SE0 detection counter
      if(line_state == 2'b00) begin
         if(dc == 255) dc_wrap <= dc_wrap + 1'b1;
      end else begin
         dc_wrap <= 0;
      end
      
      know_recv_packet <= 0;

      // see if PHY has stuff for us
      if(phy_dir & ~phy_dir_1) begin
         // rising edge of dir
         
         // make sure we're not clobbering a request from the packet layer
         can_send <= 0;
         know_recv_packet <= phy_nxt;
         dc <= 0;
         state <= ST_RX_0;
         state_next <= ST_IDLE;
      end else begin
         // do other stuff
         can_send <= 1;
         
         // accept packet data
         if(pkt_in_latch | pkt_in_latch_defer) begin  
            state <= ST_PKT_0;
         end else
			if(se0_bus_reset)
			begin
				dc_wrap <= 0;
				// switch to full-speed first then decide is this reset or suspend
				tx_cmd_code <=          TX_CMD_REGWR_IMM;
				tx_reg_addr <=          6'h4;
				tx_reg_data_wr <= {     2'b01,          // Resvd, SuspendM [disabled]
												1'b0,           // Reset (auto-cleared by PHY)
												2'b00,          // OpMode [normal]
												1'b1,           // TermSelect [enable]
												2'b01           // XcvrSel [full speed]
				};
				state <= ST_TXCMD_0;
				state_next <= ST_SUSPEND_OR_RESET;
			end
      end
   end

	ST_SUSPEND_OR_RESET:
	begin
		// distinguish reset and suspend
		// from USB 2.0 spec:
		// No earlier than 100 µs and no later than 875 µs (TWTRSTHS) after reverting to full-speed, 
		// the device must sample the state of the line. If the state is a full-speed J, 
		// the device continues with the Suspend process. 

		/* this was a suspend */
		if (dc_wrap > 30 /* > 100us */ && line_state == 2'b01 /* J state */)
			state <= ST_SUSPEND;

		/* this was a true reset */
		if (dc_wrap > 215 /* 875 us */)
			state <= ST_CHIRP_0;
		
		if(dc == 255) dc_wrap <= dc_wrap + 1'b1;

		// update linestate
		if(phy_dir & ~phy_dir_1) begin
			// rising edge of dir
			state <= ST_RX_0;
			state_next <= ST_SUSPEND_OR_RESET;
		end
	end

	ST_SUSPEND: 
	begin
		/* switch phy to "low power" (suspend) mode
		* phy_clk will be disabled in few  (5?) cycles 
		*/
		tx_cmd_code <=          TX_CMD_REGWR_IMM;
		tx_reg_addr <=          6'h4;
		tx_reg_data_wr <= {     2'b00,          // Resvd, SuspendM [enabled]
										1'b0,           // Reset (auto-cleared by PHY)
										2'b00,          // OpMode [aospan:high impedance state]
										1'b1,           // TermSelect [enable]
										2'b01           // XcvrSel [full speed]
		};
		state <= ST_TXCMD_0;
		state_next <= ST_SUSPEND_ACT;
		is_suspend <= 1;
	end

	ST_SUSPEND_ACT:
	begin
		/* we are waked up */
		if (resume_s)
			state <= ST_SUSPEND_ACT2;
	end

	ST_SUSPEND_ACT2:
	begin
		/* we need to detect resume end (about 20 msec ?)
			* from usb 2.0 spec: It must send the resume signaling for at least 20 ms and
			* then end the resume signaling in one of two ways, depending on the speed at which its port 
			* was operating when it was suspended. If the port was in low-/full-speed when suspended, 
			* the resume signaling must be ended with a standard, low-speed EOP (two low-speed bit times of 
			* SE0 followed by a J). If the port was operating in highspeed when it was suspended, the resume 
			* signaling must be ended with a transition to the high-speed idle state
		*/
		if (line_state == 2'b00 /* TODO: this for high speed only*/)
			state <= ST_SUSPEND_ACT3;
		
		// update linestate
		if (phy_dir & ~phy_dir_1) begin
			// rising edge of dir
			state <= ST_RX_0;
			state_next <= ST_SUSPEND_ACT2;
		end
	end

	ST_SUSPEND_ACT3:
	begin
		// revert phy back to previous state  (high speed?)
		tx_cmd_code <=          TX_CMD_REGWR_IMM;
		tx_reg_addr <=          6'h4;
		tx_reg_data_wr <= {     2'b01,          // Resvd, SuspendM [disabled]
										1'b0,           // Reset (auto-cleared by PHY)
										2'b00,          // OpMode [normal]
										1'b0,           // TermSelect
										2'b00           // XcvrSel [high speed]
								};
		state <= ST_TXCMD_0;
		state_next <= ST_IDLE;
		dc_wrap <= 0;
		dc <= 0;
		is_suspend <= 0;
	end

										  
   // process RX CMD or start packet
   //
   ST_RX_0: begin
      // data is passed up to the packet layer
      // see combinational logic near the top
      if(~phy_nxt) in_rx_cmd <= phy_d_in;
      // wait for end of transmission
      if(~phy_dir) begin
         state <= state_next;
      end
   end
   
   // transmit command TXCMD
   //
   ST_TXCMD_0: begin
   
      // drive command onto bus
      if(~tx_cmd_code[2]) begin
         if(~tx_cmd_code[1]) 
            phy_d_next <= {tx_cmd_code[1:0], 6'b0};               // transmit no PID
         else           
            phy_d_next <= {tx_cmd_code[1:0], tx_reg_addr[5:0]};      // immediate reg r/w
      end else begin
         if(~tx_cmd_code[1]) 
            phy_d_next <= {tx_cmd_code[1:0], 2'b0, tx_pid[3:0]};  // transmit with PID
         else           
            phy_d_next <= {tx_cmd_code[1:0], 6'b101111};       // extended reg r/w
      end
      
      if(phy_nxt) begin
         // phy has acknowledged the command
         
         if(tx_cmd_code[0]) begin
            // read reg
            // immediate only for now
            // need to insert additional branches for extended addr
            phy_d_out <= 0;
            state <= ST_TXCMD_2;
         end else begin
            // write reg
            // immediate only for now
            phy_d_out <= tx_reg_data_wr;
            phy_d_next <= 0;
            state <= ST_TXCMD_1; // assert STP
         end
      end
      
      if(~tx_cmd_code[1]) begin
         // transmit packet
         // can't afford to dally around
         state <= state_next;
      end
   end
   ST_TXCMD_1: begin
      // assert STP on reg write
      phy_stp_out <= 1'b1;
      state <= state_next;
   end
   ST_TXCMD_2: begin
      // latch reg read
      if(phy_dir) state <= ST_TXCMD_3;
   end 
   ST_TXCMD_3: begin
      // read value from PHY
      tx_reg_data_rd <= phy_d_in;
      state <= state_next;
   end
   
   // data packet send
   //
   ST_PKT_0: begin
      // accept packet data
      // implied that first byte is PID
      tx_cmd_code <= TX_CMD_XMIT_PID;
      tx_pid <= pkt_in_byte[3:0];
      can_send <= 0;
      // call TXCMD
      state <= ST_TXCMD_0;
      state_next <= ST_PKT_1;
   end
   ST_PKT_1: begin
      // packet layer now has control
      // and is handling lines
      if(phy_nxt) begin
         state <= ST_PKT_2;
         phy_d_sel <= 1;
      end
   end
   ST_PKT_2: begin
      if(pkt_in_stp) begin
         phy_d_sel <= 0;
         phy_d_out <= 0;
         phy_d_next <= 0;
         pkt_in_latch_defer <= 0;
         state <= ST_IDLE;
      end
   end
   
   // high-speed handshake chirp
   //
   ST_CHIRP_0: begin
		reset_ulpi <= 0;
      tx_cmd_code <=       TX_CMD_REGWR_IMM;
      tx_reg_addr <=       6'h4;
      tx_reg_data_wr <= {  2'b01,      // Resvd, SuspendM [disabled]
                     1'b0,       // Reset (auto-cleared by PHY)
                     2'b10,      // OpMode [chirp]
                     1'b1,    // TermSelect [enable]
                     2'b00    // XcvrSel [high speed]
      };
      state <= ST_TXCMD_0; 
      state_next <= ST_CHIRP_1;
   end
   ST_CHIRP_1: begin
		reset_ulpi <= 1;
      // transmit chirp K for >1ms (2ms)
      tx_cmd_code <=       TX_CMD_XMIT_NOPID;
      tx_reg_addr <=       6'h4;
      dc_wrap <= 0;
      state <= ST_TXCMD_0; 
      state_next <= ST_CHIRP_2;
   end
   ST_CHIRP_2: begin
      if(phy_nxt) begin
         phy_d_out <= 8'h0;
         phy_d_next <= 8'h0;
         if(dc == 255) dc_wrap <= dc_wrap + 1'b1;
         if(dc_wrap == 600) begin
            // a bit over 2ms has passed
            phy_stp_out <= 1'b1;
	    chirp_k_seen <= 0;
	    chirp_j_seen <= 0;
	    state <= ST_CHIRP_WAIT_KJKJKJ;
         end
      end
   end
   ST_CHIRP_WAIT_KJKJKJ: begin
	   /* according ULPI spec rev 1.1:
	   minimum K-J-K-J-K-J sequence should be seen
	   before enabling HS termination
	   */
	  if (chirp_k_seen > 3 && chirp_j_seen > 3) begin
		  // now we can switch to normal HS mode
		  state <= ST_CHIRP_3;
	  end
	  else if(phy_dir & ~phy_dir_1) begin
		  state <= ST_RX_0;
		  state_next <= ST_CHIRP_WAIT_KJKJKJ;
		  if (line_state == 2'b01)
			  chirp_k_seen <= chirp_k_seen + 1;
		  if (line_state == 2'b10)
			  chirp_j_seen <= chirp_j_seen + 1;
	  end
  end
  ST_CHIRP_3: begin
	  // switch to normal HS mode now
	  tx_cmd_code <=       TX_CMD_REGWR_IMM;
	  tx_reg_addr <=       6'h4;
	  tx_reg_data_wr <= {  2'b01,      // Resvd, SuspendM [disabled]
		  1'b0,       // Reset (auto-cleared by PHY)
		  2'b00,      // OpMode [normal]
		  1'b0,    // TermSelect [enable]
		  2'b00    // XcvrSel [high speed]
		  };
		  if(~phy_dir && phy_d_in == 8'h0) state <= ST_TXCMD_0; 
		  state_next <= ST_CHIRP_5;
  end
  ST_CHIRP_5: begin
	  stat_hs <= 1'b1;
	  state <= ST_IDLE;
  end
  default: state <= ST_RST_0;
   endcase

   if(~reset_2) state <= ST_RST_0;
   
   // detect a change in Vbus
   //
   // this works fine with regular USB 2.0 PHYs, however
   // the TUSB1310A has a silicon bug where the ULPI Vbus 
   // status is incorrectly reported, causing erratic 
   // disconnects.
   //
   if(~opt_ignore_vbus_2) begin
      if(~vbus_valid & vbus_valid_1) begin
         reset_ulpi <= 0;
         state <= ST_RST_0;
      end
   end
end
endmodule
	
