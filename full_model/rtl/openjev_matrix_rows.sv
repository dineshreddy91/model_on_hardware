`timescale 1ns/1ps
// Batched INT8 matvec with direct 32-byte HBM weight reads and tensor-port activations/results.
// The external AXI adapter arbitrates the weight read channel and tensor port.
module openjev_matrix_rows #(
  parameter integer PARALLEL_BATCHES=2,
  parameter [63:0] WATCHDOG_CYCLES=64'd100000000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [31:0] batch_count,rows,columns,weight_base,
  input wire [31:0] source,destination,
  output wire weight_request_valid,
  input wire weight_request_ready,
  output wire [4:0] weight_bank,
  output wire [28:0] weight_address,
  input wire weight_response_valid,
  output wire weight_response_ready,
  input wire [255:0] weight_response_data,
  input wire [1:0] weight_response_status,
  output wire memory_valid,
  input wire memory_ready,
  output logic memory_write,
  output logic [31:0] memory_tensor,memory_index,memory_data,
  input wire memory_response_valid,
  output wire memory_response_ready,
  input wire [31:0] memory_response_data,
  input wire memory_response_error,
  output reg done,
  output wire fault
);
  localparam IDLE=0,LAUNCH=1,RUN=2,FAILED=3;
  reg [1:0] state;
  reg [31:0] batches,nr,nc,base,src,dst,batch_base,input_base,output_base;
  reg [63:0] cycles;
  reg [PARALLEL_BATCHES-1:0] enabled,launched,finished;
  wire [PARALLEL_BATCHES-1:0] cr,mv,mw,mrr,wrv,wrr,ld,lf;
  wire [31:0] mt[PARALLEL_BATCHES],mi[PARALLEL_BATCHES],md[PARALLEL_BATCHES];
  wire [4:0] wb[PARALLEL_BATCHES];
  wire [28:0] wa[PARALLEL_BATCHES];
  reg waiting,weight_waiting,locked;
  integer selected,owner,locked_owner;
  reg found;
  reg [31:0] input_offset[PARALLEL_BATCHES],output_offset[PARALLEL_BATCHES];
  wire running=state==RUN;
  wire lane_reset=rst_n&&state!=IDLE&&state!=FAILED;
  assign command_ready=rst_n&&state==IDLE;
  assign fault=state==FAILED;
  always_comb begin
    selected=0;found=0;
    for(integer i=0;i<PARALLEL_BATCHES;i=i+1)
      if(!found&&enabled[i]&&mv[i]) begin selected=i;found=1;end
    if(locked) begin selected=locked_owner;found=1;end
    memory_write=mw[selected];memory_tensor=mt[selected];memory_data=md[selected];
    memory_index=mi[selected]+(mw[selected]?output_offset[selected]:input_offset[selected]);
  end
  assign memory_valid=rst_n&&running&&!waiting&&found;
  assign memory_response_ready=rst_n&&running&&waiting&&mrr[owner];
  // All active lanes consume the identical weight stream in lockstep. Each
  // fetched 32-byte vector drives two independent 32-lane INT8 dot products.
  assign weight_request_valid=rst_n&&running&&!weight_waiting&&(&(wrv|~enabled));
  assign weight_bank=wb[0];
  assign weight_address=wa[0];
  assign weight_response_ready=rst_n&&running&&weight_waiting&&(&(wrr|~enabled));
  for(genvar g=0;g<PARALLEL_BATCHES;g=g+1) begin: lanes
    localparam integer LANE=g;
    openjev_matrix_rows_lane #(.WATCHDOG_CYCLES(WATCHDOG_CYCLES)) unit(
      .clk(clk),.rst_n(lane_reset),.command_valid(state==LAUNCH&&enabled[LANE]&&!launched[LANE]),
      .command_ready(cr[LANE]),.batch_count(32'd1),.rows(nr),.columns(nc),.weight_base(base),.source(src),.destination(dst),
      .weight_request_valid(wrv[LANE]),.weight_request_ready(weight_request_valid&&weight_request_ready&&enabled[LANE]),
      .weight_bank(wb[LANE]),.weight_address(wa[LANE]),
      .weight_response_valid(weight_response_valid&&weight_response_ready&&enabled[LANE]),
      .weight_response_ready(wrr[LANE]),.weight_response_data(weight_response_data),.weight_response_status(weight_response_status),
      .memory_valid(mv[LANE]),.memory_ready(memory_valid&&memory_ready&&selected==LANE),
      .memory_write(mw[LANE]),.memory_tensor(mt[LANE]),.memory_index(mi[LANE]),.memory_data(md[LANE]),
      .memory_response_valid(memory_response_valid&&waiting&&owner==LANE&&running),
      .memory_response_ready(mrr[LANE]),.memory_response_data(memory_response_data),.memory_response_error(memory_response_error),
      .done(ld[LANE]),.fault(lf[LANE]));
  end
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;done<=0;cycles<=0;batches<=0;nr<=0;nc<=0;base<=0;src<=0;dst<=0;
      batch_base<=0;input_base<=0;output_base<=0;enabled<=0;launched<=0;finished<=0;
      waiting<=0;weight_waiting<=0;locked<=0;owner<=0;locked_owner<=0;
      for(integer i=0;i<PARALLEL_BATCHES;i=i+1) begin input_offset[i]<=0;output_offset[i]<=0;end
    end else begin
      done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(batch_count==0||batch_count>4096||rows==0||rows>8192||columns==0||columns>4096||columns[4:0]!=0||
             weight_base[11:0]!=0||weight_base>=32'h02000000||source==destination) state<=FAILED;
          else begin
            batches<=batch_count;nr<=rows;nc<=columns;base<=weight_base;src<=source;dst<=destination;
            batch_base<=0;input_base<=0;output_base<=0;cycles<=0;launched<=0;finished<=0;waiting<=0;weight_waiting<=0;locked<=0;
            for(integer i=0;i<PARALLEL_BATCHES;i=i+1) begin
              enabled[i]<=i<batch_count;input_offset[i]<=i*columns;output_offset[i]<=i*rows;
            end
            state<=LAUNCH;
          end
        end
        LAUNCH: begin
          launched<=launched|(cr&enabled);
          if(&((launched|cr)|~enabled))state<=RUN;
        end
        RUN: begin
          finished<=finished|(ld&enabled);
          if(memory_valid&&!memory_ready)begin locked<=1;locked_owner<=selected;end
          if(memory_valid&&memory_ready)begin waiting<=1;owner<=selected;locked<=0;end
          if(memory_response_valid&&memory_response_ready)waiting<=0;
          if(weight_request_valid&&weight_request_ready)begin
            weight_waiting<=1;
            for(integer i=0;i<PARALLEL_BATCHES;i=i+1)
              if(enabled[i]&&(wb[i]!=wb[0]||wa[i]!=wa[0]))state<=FAILED;
          end
          if(weight_response_valid&&weight_response_ready)weight_waiting<=0;
          if(&(finished|~enabled))begin
            if(batch_base+PARALLEL_BATCHES>=batches)begin done<=1;state<=IDLE;end
            else begin
              batch_base<=batch_base+PARALLEL_BATCHES;
              input_base<=input_base+PARALLEL_BATCHES*nc;output_base<=output_base+PARALLEL_BATCHES*nr;
              launched<=0;finished<=0;
              for(integer i=0;i<PARALLEL_BATCHES;i=i+1)begin
                enabled[i]<=batch_base+PARALLEL_BATCHES+i<batches;
                input_offset[i]<=input_base+(PARALLEL_BATCHES+i)*nc;
                output_offset[i]<=output_base+(PARALLEL_BATCHES+i)*nr;
              end
              state<=LAUNCH;
            end
          end
        end
        FAILED: state<=FAILED;
        default: state<=FAILED;
      endcase
      if(state!=IDLE&&state!=FAILED)begin
        cycles<=cycles+1;
        if((|(lf&enabled))||cycles>=WATCHDOG_CYCLES-1)begin state<=FAILED;done<=0;end
      end
    end
  end
endmodule

`timescale 1ns/1ps
// Batched INT8 matvec with direct 32-byte HBM weight reads and tensor-port activations/results.
// The external AXI adapter arbitrates the weight read channel and tensor port.
module openjev_matrix_rows_lane #(
  parameter [63:0] WATCHDOG_CYCLES=64'd100000000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [31:0] batch_count,rows,columns,weight_base,
  input wire [31:0] source,destination,
  output wire weight_request_valid,
  input wire weight_request_ready,
  output wire [4:0] weight_bank,
  output wire [28:0] weight_address,
  input wire weight_response_valid,
  output wire weight_response_ready,
  input wire [255:0] weight_response_data,
  input wire [1:0] weight_response_status,
  output wire memory_valid,
  input wire memory_ready,
  output reg memory_write,
  output reg [31:0] memory_tensor,memory_index,memory_data,
  input wire memory_response_valid,
  output wire memory_response_ready,
  input wire [31:0] memory_response_data,
  input wire memory_response_error,
  output reg done,
  output wire fault
);
  localparam IDLE=0,CHECK=1,LAUNCH=2,READ=3,SAVE=4,FEED=5,WEIGHT_START=6,
    RUN=7,ACK=8,WAIT_DONE=9,NEXT=10,MEM_ISSUE=11,MEM_WAIT=12,FAILED=13;
  reg [3:0] state,return_state;
  reg [31:0] batches,nr,nc,base,src,dst,batch_index,ci,input_offset,output_offset,byte_count;
  reg [255:0] activation;
  reg [31:0] result_q;
  reg [63:0] cycles;
  wire cr,ce,ar,wr,rv,rl,cb,cd,reader_ready,reader_error,reader_fault,wv,wl,reader_done;
  wire [255:0] wd;
  wire [31:0] rd,rr;
  assign command_ready=rst_n&&state==IDLE;
  assign memory_valid=rst_n&&state==MEM_ISSUE;
  assign memory_response_ready=rst_n&&state==MEM_WAIT;
  assign fault=state==FAILED;
  openjev_int8_matvec compute(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH),.command_ready(cr),.columns(nc),.rows(nr),
    .command_error(ce),.activation_valid(state==FEED),.activation_ready(ar),.activation_data(activation),
    .weight_valid(wv),.weight_ready(wr),.weight_data(wd),.result_valid(rv),.result_ready(state==ACK),
    .result_data(rd),.result_row(rr),.result_last(rl),.busy(cb),.done(cd));
  openjev_hbm_weight_reader reader(
    .clk(clk),.rst_n(rst_n),.command_valid(state==WEIGHT_START),.command_ready(reader_ready),
    .base_address(base[28:0]),.byte_count(byte_count),.command_error(reader_error),
    .request_valid(weight_request_valid),.request_ready(weight_request_ready),
    .request_bank(weight_bank),.request_address(weight_address),
    .response_valid(weight_response_valid),.response_ready(weight_response_ready),
    .response_data(weight_response_data),.response_status(weight_response_status),
    .weight_valid(wv),.weight_ready(wr),.weight_data(wd),.weight_last(wl),.done(reader_done),.fault(reader_fault));
  task access;
    input write;
    input [31:0] tensor_id,element,data;
    input [3:0] next_state;
    begin memory_write<=write;memory_tensor<=tensor_id;memory_index<=element;memory_data<=data;return_state<=next_state;state<=MEM_ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;return_state<=IDLE;batches<=0;nr<=0;nc<=0;base<=0;src<=0;dst<=0;batch_index<=0;ci<=0;
      input_offset<=0;output_offset<=0;byte_count<=0;activation<=0;result_q<=0;cycles<=0;
      memory_write<=0;memory_tensor<=0;memory_index<=0;memory_data<=0;done<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(batch_count==0||batch_count>4096||rows==0||rows>8192||columns==0||columns>4096||columns[4:0]!=0||
             weight_base[11:0]!=0||weight_base>=32'h02000000||source==destination) state<=FAILED;
          else begin
            batches<=batch_count;nr<=rows;nc<=columns;base<=weight_base;src<=source;dst<=destination;
            byte_count<=rows*columns;batch_index<=0;ci<=0;input_offset<=0;output_offset<=0;cycles<=0;state<=CHECK;
          end
        end
        CHECK: if({1'b0,base}+((({1'b0,byte_count}+8191)>>13)<<8)>33'h002000000) state<=FAILED;else state<=LAUNCH;
        LAUNCH: if(cr) state<=READ;
        READ: access(0,src,input_offset+ci,0,SAVE);
        SAVE: begin
          activation[ci[4:0]*8+:8]<=result_q[7:0];
          if(ci[4:0]==31) state<=FEED;else begin ci<=ci+1;state<=READ;end
        end
        FEED: if(ar) begin
          if(ci==nc-1) state<=WEIGHT_START;else begin ci<=ci+1;state<=READ;end
        end
        WEIGHT_START: if(reader_ready) state<=RUN;
        RUN: if(rv) access(1,dst,output_offset+rr,rd,ACK);
        ACK: if(rl) state<=WAIT_DONE;else state<=RUN;
        WAIT_DONE: if(cd) state<=NEXT;
        NEXT: begin
          if(batch_index==batches-1) begin done<=1;state<=IDLE;end
          else begin batch_index<=batch_index+1;input_offset<=input_offset+nc;output_offset<=output_offset+nr;ci<=0;state<=LAUNCH;end
        end
        MEM_ISSUE: if(memory_ready) state<=MEM_WAIT;
        MEM_WAIT: if(memory_response_valid) begin
          if(memory_response_error) state<=FAILED;
          else begin if(!memory_write) result_q<=memory_response_data;state<=return_state;end
        end
        FAILED: state<=FAILED;
        default: state<=FAILED;
      endcase
      if(ce||reader_error||reader_fault) state<=FAILED;
      if(state!=IDLE&&state!=FAILED) begin
        cycles<=cycles+1;
        if(cycles>=WATCHDOG_CYCLES-1) begin done<=0;state<=FAILED;end
      end
    end
  end
endmodule
