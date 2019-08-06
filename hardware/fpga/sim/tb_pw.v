//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/20/2019 04:26:22 PM
// Design Name: 
// Module Name: phywhisperer_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none
`include "defines.v"

module tb_pw();

    parameter pUSB_CLOCK_PERIOD = 10;
    parameter pFE_CLOCK_PERIOD = 16;

    // these parameters define the testcase:
    parameter pMIN_FE_DELAY = 0;
    parameter pMAX_FE_DELAY = 7;
    parameter pDELAY_MODE = 0;
    parameter pVERBOSE = 1;
    parameter pSHOW_TIME_EVENTS = 0;
    parameter pNUM_EVENTS = 20;
    parameter pNUM_REPEATS = 2;
    parameter pPRETRIG_BYTES_MIN = 0;
    parameter pPRETRIG_BYTES_MAX = 200;
    parameter pPATTERN_BYTES_MIN = 2;
    parameter pPATTERN_BYTES_MAX = 8;
    parameter pPVALID = 50;
    parameter pSEED = 1;


    reg           usb_clk;
    wire [7:0]    USB_Data;
    reg  [7:0]    USB_wdata;
    reg  [7:0]    USB_Addr;
    reg           USB_nRD;
    reg           USB_nWE;
    reg           USB_nCS;
    wire          USB_SPARE0;
    reg           USB_SPARE1;

    /* FRONT END CONNECTIONS */
    reg  fe_clk;
    reg  fe_txrdy;
    reg  fe_rxactive;
    reg  fe_id_dig;
    reg  fe_linestate0;
    reg  fe_linestate1;
    reg  fe_hostdisc;
    reg  fe_sessend;
    wire [7:0] fe_data;
    reg  [7:0] fe_wdata;
    reg  fe_rxvalid;
    reg  fe_sessvld;
    reg  fe_rxerror;
    reg  fe_vbusvld;

    /* 20-PIN USER HEADER CONNECTOR */
    reg  [7:0] userio_d;
    reg  userio_clk;
    reg  [23:0] read_data;
    reg  [7:0] data;
    reg  [7:0] expected_data;
    reg  [1:0] command;
    reg  [`FE_FIFO_FULLTIME_LEN-1:0] timestamp;
    reg  dut_rxactive;
    reg  dut_rxerror;
    reg  dut_sessvld;
    reg  dut_sessend;
    reg  dut_vbusvld;
    reg  [4:0] dut_usbstat;

    /* 20-PIN CHIPWHISPERER CONNECTOR */
    wire cw_clk;
    wire cw_trig;

    reg  reset;
    int  seed;


   initial begin
      seed = pSEED;
      $display("Running with pSEED=%0d", pSEED);
      $urandom(seed);
      $dumpfile("tb.fst");
      $dumpvars(0, tb_pw);
      usb_clk = 1'b1;
      fe_clk = 1'b1;
      reset = 1'b0;

      USB_wdata = 0;
      USB_Addr = 0;
      USB_nRD = 1;
      USB_nWE = 1;
      USB_nCS = 1;
      USB_SPARE1 = 1;

      fe_txrdy = 0;
      fe_rxactive = 0;
      fe_id_dig = 0;
      fe_linestate0 = 0;
      fe_linestate1 = 0;
      fe_hostdisc = 0;
      fe_sessend = 0;
      fe_wdata = 0;
      fe_rxvalid = 0;
      fe_sessvld = 0;
      fe_rxerror = 0;
      fe_vbusvld = 0;

      //userio_d = 0;
      //userio_clk = 0;

      #(pUSB_CLOCK_PERIOD*2) reset = 1;
      #(pUSB_CLOCK_PERIOD*2) reset = 0;
   end

   int i;
   int txindex;
   int rx_dataindex;
   int rx_readindex;
   int send_iteration;
   int receive_iteration;
   int errors;
   int time_counter;
   string str;
   reg fe_data_event [0:2047];
   reg [7:0] fe_bytes [0:2047];
   reg [4:0] fe_stat [0:2047];
   reg [4:0] pattern_fe_stat;
   reg [15:0] fe_times [0:2047];
   reg [7:0] sniff_bytes [0:7];
   reg [7:0] match_pattern [0:pPATTERN_BYTES_MAX-1];
   int pattern_bytes;
   int pretrig_bytes;
   bit armed;
   bit fifo_empty;


   // timeout thread:
   initial begin
      //#(pFE_CLOCK_PERIOD*100000);
      #(pFE_CLOCK_PERIOD*50000);
      errors += 1;
      $display("ERROR: global timeout");
      $display("SIMULATION FAILED (%0d errors).", errors);
      $finish;
   end

   // FE feeding thread:
   initial begin
      errors = 0;
      #(pFE_CLOCK_PERIOD*100);
      //write_1byte(`REG_TIMESTAMPS_DISABLE, 8'h01); // disable timestamps

      // write pattern and mask:
      pattern_bytes = $urandom_range(pPATTERN_BYTES_MIN, pPATTERN_BYTES_MAX);
      rw_lots_bytes(`REG_PATTERN);
      for (i = 0; i < pattern_bytes; i = i + 1) begin
         match_pattern[i] = $urandom;
         write_next_byte(match_pattern[i]);
      end
      rw_lots_bytes(`REG_PATTERN_MASK);
      for (i = 0; i < pattern_bytes; i = i + 1)
         write_next_byte(8'hFF);

      write_1byte(`REG_PATTERN_BYTES, pattern_bytes);
      write_1byte(`REG_PATTERN_ACTION, `PM_CAPTURE);
      write_1byte(`REG_CAPTURE_LEN, pNUM_EVENTS);


      if (pVERBOSE) begin
         $display("--------------------------------------|-------------------------------");
         $display("FE testbench sending:                 | PhyWhisperer DUT receiving:");
         $display("--------------------------------------|-------------------------------");
      end

      for (send_iteration = 0; send_iteration < pNUM_REPEATS; send_iteration = send_iteration + 1) begin
      armed = 0;
      $display("Tx Iteration %d:", send_iteration);
      write_1byte(`REG_ARM, 8'h01);
      armed = 1;

      @(posedge fe_clk);
      // send pre-trigger data:
      // TODO: ensure we aren't randomly matching the programmed pattern here
      pretrig_bytes = $urandom_range(pPRETRIG_BYTES_MIN, pPRETRIG_BYTES_MAX);
      $display("Sending pre-trigger data (%0d events):", pretrig_bytes);
      for (txindex = 0; txindex < pretrig_bytes; txindex = txindex + 1) begin
         fe_bytes[0] = $urandom;
         fe_stat[0] = $urandom;
         get_delay(fe_times[0]);
         get_valid(fe_data_event[0]);
         send_fe_data(fe_data_event[0], fe_bytes[0], fe_stat[0], fe_times[0]);
         if (pVERBOSE)
            if (fe_data_event[0])
               $display("DATA: data=%h, stat=%h, delay=%0d", fe_bytes[0], fe_stat[0], fe_times[0]);
            else
               $display("STAT:          stat=%h, delay=%0d", fe_stat[0], fe_times[0]);
      end
      fe_rxvalid = 1'b0;

      // send pattern which will match:
      $display("\nSending matching pattern (%0d bytes):", pattern_bytes);
      txindex = 0;
      while (txindex < pattern_bytes) begin
         pattern_fe_stat = $urandom;
         get_delay(fe_times[0]);
         get_valid(fe_data_event[0]);
         if (fe_data_event[0]) begin
            fe_bytes[0] = match_pattern[txindex];
            txindex = txindex + 1;
         end
         else
            fe_bytes[0] = $urandom;
         send_fe_data(fe_data_event[0], fe_bytes[0], pattern_fe_stat, fe_times[0]);
         if (pVERBOSE)
            if (fe_data_event[0])
               $display("DATA: data=%h, stat=%h, delay=%0d", fe_bytes[0], pattern_fe_stat, fe_times[0]);
            else
               $display("STAT:          stat=%h, delay=%0d", pattern_fe_stat, fe_times[0]);
      end
      fe_rxvalid = 1'b0;

      // send data that will be captured:
      get_delay(fe_times[0]);
      repeat (fe_times[0]) @(posedge fe_clk);
      fe_times[0] = 0; // by definition
      $display("\nSending data that will be captured:");
      for (txindex = 0; txindex < pNUM_EVENTS; txindex = txindex + 1) begin
         // Notes we are sending pNUM_EVENTS data/stat events; if large time deltas between events
         // generate TIME commands, then the number of events generated by the hardware will be greater
         // than pNUM_EVENTS!
         // To avoid over complicating the testbench, let's just accept this disparity.
         fe_bytes[txindex] = $urandom;
         fe_stat[txindex] = $urandom;
         get_delay(fe_times[txindex+1]);
         get_valid(fe_data_event[txindex]);
         // if rxvalid is low, then stat must change -- otherwise there is no event to pick up
         if (fe_data_event[txindex] == 0) begin
            if (txindex == 0) begin
               while (fe_stat[txindex] == pattern_fe_stat)
                  fe_stat[txindex] = $urandom;
            end
            else begin
               while (fe_stat[txindex] == fe_stat[txindex-1])
                  fe_stat[txindex] = $urandom;
            end
         end

         // TODO: consider driving fe_stat independently of fe_bytes?
         send_fe_data(fe_data_event[txindex], fe_bytes[txindex], fe_stat[txindex], fe_times[txindex+1]);
         if (pVERBOSE)
            if (fe_data_event[txindex])
               $display("DATA: data=%h, stat=%h, delay=%0d", fe_bytes[txindex], fe_stat[txindex], fe_times[txindex+1]);
            else
               $display("STAT:          stat=%h, delay=%0d", fe_stat[txindex], fe_times[txindex+1]);
      end
      fe_rxvalid = 1'b0;


      //#(pFE_CLOCK_PERIOD*2000);
      // sync up with receive block:
      wait (rx_readindex == pNUM_EVENTS);
      //wait (rx_dataindex == pNUM_EVENTS);

      /* for manual verification that the next re-arm and trigger will work:
      write_1byte(`REG_ARM, 8'h01);
      //write_1byte(`REG_ARM, 8'h01);
      @(posedge fe_clk);
      for (i = 0; i < pattern_bytes; i = i + 1)
         send_fe_data(1'b1, match_pattern[i], 0, 0);
      fe_rxvalid = 1'b0;
      #(pFE_CLOCK_PERIOD*20);
      */


      end


      if (errors)
         $display("SIMULATION FAILED (%0d errors).", errors);
      else
         $display("Simulation passed!");
      $finish;
   end


   // FIFO read thread:
   initial begin
      for (receive_iteration = 0; receive_iteration < pNUM_REPEATS; receive_iteration = receive_iteration + 1) begin
      $display("Rx Iteration %d:", receive_iteration);
      rx_dataindex = 0;
      time_counter = 0;
      // sync up with transmit block:
      wait(send_iteration == receive_iteration);
      wait(armed);
      // ensure FIFO is empty:
      fifo_empty = 0;
      while (fifo_empty == 0) begin
         read_1byte(`REG_SNIFF_FIFO_STAT, fifo_empty);
      end

      for (rx_readindex = 0; rx_readindex < pNUM_EVENTS; rx_readindex = rx_readindex + 1) begin
      //while (rx_dataindex < pNUM_EVENTS) begin
         wait (U_dut.U_reg_pw.sniff_fifo_empty == 1'b0);
         rw_lots_bytes(`REG_SNIFF_FIFO_RD);
         read_next_byte(read_data[7:0]);
         read_next_byte(read_data[15:8]);
         read_next_byte(read_data[23:16]);
         command = read_data[`FE_FIFO_CMD_START +: `FE_FIFO_CMD_BIT_LEN];

         if ( (command == `FE_FIFO_CMD_DATA) || (command == `FE_FIFO_CMD_STAT) ) begin
            data = read_data[`FE_FIFO_DATA_START +: `FE_FIFO_DATA_LEN];
            dut_rxactive = read_data[`FE_FIFO_RXACTIVE_BIT];
            dut_rxerror = read_data[`FE_FIFO_RXERROR_BIT];
            dut_sessvld = read_data[`FE_FIFO_SESSVLD_BIT];
            dut_sessend = read_data[`FE_FIFO_SESSEND_BIT];
            dut_vbusvld = read_data[`FE_FIFO_VBUSVLD_BIT];
            dut_usbstat = read_data[`FE_FIFO_STATUS_BITS_START +: `FE_FIFO_STATUS_BITS_LEN];

            if (command == `FE_FIFO_CMD_DATA) begin
               expected_data = fe_bytes[rx_dataindex];
               str = "DATA";
            end
            else begin
               expected_data = 8'd0;
               str = "STAT";
            end

            timestamp = read_data[`FE_FIFO_TIME_START +: `FE_FIFO_SHORTTIME_LEN];
            time_counter = time_counter + timestamp;
            if ( (data == expected_data) && (dut_usbstat == fe_stat[rx_dataindex]) && (time_counter == fe_times[rx_dataindex]) ) begin
               if (pVERBOSE)
                  $display("\t\t\t\t\t%s: data=%h, stat=%h, time=%0d, total time=%0d", str, data, dut_usbstat, timestamp, time_counter);
            end
            else begin
               errors += 1;
               if ( (data == expected_data) && (dut_usbstat == fe_stat[rx_dataindex]))
                  $display("\t\t\t\t\t*** ERROR on %s read #%0d at time %0t: got good data (%h) and stat (%h), bad time: expected %0d, got %0d", str, rx_dataindex, $time, data, dut_usbstat, fe_times[rx_dataindex], time_counter);
               else if (time_counter == fe_times[rx_dataindex])
                  $display("\t\t\t\t\t*** ERROR on %s read #%0d at time %0t: got good timestamp (%0d), bad data (got %h, expected %h) or stat (got %h, expected %h)", str, rx_dataindex, $time, timestamp, data, expected_data, dut_usbstat, fe_stat[rx_dataindex]);
               else
                  $display("\t\t\t\t\t*** ERROR on %s read #%0d at time %0t: bad data (got %h, expected %h), stat (got %h, expected %h) and time (got %0d, expected %0d)", str, rx_dataindex, $time, data, expected_data, dut_usbstat, fe_stat[rx_dataindex], time_counter, fe_times[rx_dataindex]);
            end
            rx_dataindex = rx_dataindex + 1;
            time_counter = 0;
         end


         else if (command == `FE_FIFO_CMD_TIME) begin
            timestamp = read_data[`FE_FIFO_TIME_START +: `FE_FIFO_FULLTIME_LEN];
            time_counter = time_counter + timestamp;
            if (pVERBOSE && pSHOW_TIME_EVENTS)
               $display("\t\t\t\t\ttime=%0d", timestamp);
         end

         else begin
            errors += 1;
            $display("\t\t\t\t\t*** ERROR: Unknown command!");
         end

         /* check sniff register (obsolete)
         if (rx_dataindex == pNUM_EVENTS) begin
            rw_lots_bytes(`REG_FE_SNIFF);
            for (k = 0; k < 8; k = k + 1) begin
               read_next_byte(sniff_bytes[k]);
               $display("Sniff byte: %h", sniff_bytes[k]);
            end
         end
         */

      end
      end
   end


   assign USB_Data = USB_nWE? 8'bz : USB_wdata;
   assign fe_data = fe_wdata;
   assign USB_SPARE0 = reset;

   task write_1byte;
      input [7:0] address;
      input [7:0] data;
      @(posedge usb_clk);
      USB_SPARE1 = 0;
      USB_Addr = address;
      @(posedge usb_clk);
      USB_SPARE1 = 1;
      repeat(4) @(posedge usb_clk);
      USB_wdata = data;
      USB_nWE = 0;
      @(posedge usb_clk);
      USB_nWE = 1;
      USB_nCS = 0;
      @(posedge usb_clk);
      USB_nCS = 1;
   endtask



   task read_1byte;
      input [7:0] address;
      output [7:0] data;
      @(posedge usb_clk);
      USB_SPARE1 = 0;
      USB_Addr = address;
      @(posedge usb_clk);
      USB_SPARE1 = 1;
      repeat(4) @(posedge usb_clk);
      USB_nRD = 0;
      USB_nCS = 0;
      @(posedge usb_clk);
      USB_nCS = 1;
      //data = USB_Data;
      @(posedge usb_clk);
      #1 data = USB_Data;
      @(posedge usb_clk);
      USB_nRD = 1;
   endtask

   task rw_lots_bytes;
      input [7:0] address;
      @(posedge usb_clk);
      USB_SPARE1 = 0;
      USB_Addr = address;
      @(posedge usb_clk);
      USB_SPARE1 = 1;
      repeat(4) @(posedge usb_clk);
   endtask

   task read_next_byte;
      output [7:0] data;
      USB_nRD = 0;
      USB_nCS = 0;
      @(posedge usb_clk);
      USB_nCS = 1;
      @(posedge usb_clk);
      #1 data = USB_Data;
      @(posedge usb_clk);
      USB_nRD = 1;
      @(posedge usb_clk);
   endtask

   task write_next_byte;
      input [7:0] data;
      USB_wdata = data;
      USB_nWE = 0;
      @(posedge usb_clk);
      USB_nWE = 1;
      USB_nCS = 0;
      @(posedge usb_clk);
      USB_nCS = 1;
   endtask


   task send_fe_data;
      input rxvalid;
      input [7:0] data;
      input [4:0] stat;
      input [15:0] delay;
      fe_rxvalid = rxvalid;
      fe_wdata = data;
      fe_rxactive = stat[`FE_FIFO_RXACTIVE_BIT - `FE_FIFO_STATUS_BITS_START];
      fe_rxerror = stat[`FE_FIFO_RXERROR_BIT - `FE_FIFO_STATUS_BITS_START];
      fe_sessvld = stat[`FE_FIFO_SESSVLD_BIT - `FE_FIFO_STATUS_BITS_START];
      fe_sessend = stat[`FE_FIFO_SESSEND_BIT - `FE_FIFO_STATUS_BITS_START];
      fe_vbusvld = stat[`FE_FIFO_VBUSVLD_BIT - `FE_FIFO_STATUS_BITS_START];

      @(posedge fe_clk);
      if (delay > 0) begin
         fe_rxvalid = 0;
         fe_wdata = 0;
      end
      repeat (delay) @(posedge fe_clk);
   endtask


   task get_delay;
      output [15:0] delay;
      if (pDELAY_MODE == 0)
         delay = $urandom_range(pMIN_FE_DELAY, pMAX_FE_DELAY);
      else if (pDELAY_MODE == 1) begin
         delay = $urandom_range(0, 1);
         if (delay == 1) delay = $urandom_range(pMIN_FE_DELAY, pMAX_FE_DELAY);
         else delay = 0;
      end
   endtask


   task get_valid;
      output valid;
      if ($urandom_range(0, 100) < pPVALID)
         valid = 1;
      else
         valid = 0;
   endtask


   always #(pUSB_CLOCK_PERIOD/2) usb_clk = !usb_clk;
   always #(pFE_CLOCK_PERIOD/2) fe_clk = !fe_clk;

   // TODO: repeat this for all DUT inputs
   wire #1 fe_id_dig_out      = fe_id_dig;
   wire #1 fe_txrdy_out       = fe_txrdy;
   wire #1 fe_rxactive_out    = fe_rxactive;
   wire #1 fe_linestate0_out  = fe_linestate0;
   wire #1 fe_linestate1_out  = fe_linestate1;
   wire #1 fe_hostdisc_out    = fe_hostdisc;
   wire #1 fe_sessend_out     = fe_sessend;
   wire [7:0] #1 fe_data_out  = fe_data;
   wire #1 fe_rxvalid_out     = fe_rxvalid;
   wire #1 fe_sessvld_out     = fe_sessvld;
   wire #1 fe_rxerror_out     = fe_rxerror;
   wire #1 fe_vbusvld_out     = fe_vbusvld;

phywhisperer_top U_dut (
    /* USB CHIP CONNECTIONS */
    .usb_clk            (usb_clk    ),
    .USB_Data           (USB_Data   ),
    .USB_Addr           (USB_Addr   ),
    .USB_nRD            (USB_nRD    ),
    .USB_nWE            (USB_nWE    ),
    .USB_nCS            (USB_nCS    ),
    .USB_SPARE0         (USB_SPARE0 ),
    .USB_SPARE1         (USB_SPARE1 ),

    /* FRONT END CONNECTIONS */
    .fe_xcvrsel0        (), // unused
    .fe_xcvrsel1        (), // unused
    .fe_termsel         (), // unused
    .fe_suspendn        (), // unused
    .fe_txvalid         (), // unused
    .fe_reset           (), // unused
    .fe_chrgvbus        (), // unused
    .fe_opmode0         (), // unused
    .fe_opmode1         (), // unused
    .fe_idpullup        (), // unused
    .fe_dischrgvbus     (), // unused
    .fe_dppd            (), // unused
    .fe_dmpd            (), // unused
    .fe_id_dig          (fe_id_dig_out     ),
    .fe_txrdy           (fe_txrdy_out      ),
    .fe_rxactive        (fe_rxactive_out   ),
    .fe_linestate0      (fe_linestate0_out ),
    .fe_linestate1      (fe_linestate1_out ),
    .fe_hostdisc        (fe_hostdisc_out   ),
    .fe_sessend         (fe_sessend_out    ),
    .fe_clk             (fe_clk            ),
    .fe_data            (fe_data_out       ),
    .fe_rxvalid         (fe_rxvalid_out    ),
    .fe_sessvld         (fe_sessvld_out    ),
    .fe_rxerror         (fe_rxerror_out    ),
    .fe_vbusvld         (fe_vbusvld_out    ),

    /* 20-PIN USER HEADER CONNECTOR */
    .userio_d           (userio_d),
    .userio_clk         (userio_clk),

    /* 20-PIN CHIPWHISPERER CONNECTOR */
    .cw_clk             (cw_clk),
    .cw_trig            (cw_trig)
    );

endmodule
`default_nettype wire
