`timescale 1ns/1ps
// Graph opcodes 22/23: FPGA-controlled multihead iteration and tensor indexing.
// Memory returns raw FP32 words (or raw INT32 mask values). Its write response
// must acknowledge committed storage, not merely acceptance of a write request.
module openjev_head_dispatch(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [511:0] command_data,
  output wire completion_valid,
  input wire completion_ready,
  output reg [31:0] completion_tag,
  output wire completion_error,
  output wire memory_valid,
  input wire memory_ready,
  output reg memory_write,
  output reg [31:0] memory_tensor,memory_index,memory_data,
  input wire memory_response_valid,
  output wire memory_response_ready,
  input wire [31:0] memory_response_data,
  input wire memory_response_error
);
  localparam IDLE=0,CHECK=1,LAUNCH=2,RUN=3,COMPLETE=4,FAILED=5;
  localparam IO_IDLE=0,IO_READ=1,IO_WRITE=2,IO_INDEX=3,IO_MULT=4,IO_MAP=5,IO_ISSUE=6;
  reg [2:0] state;
  reg [2:0] io_state;
  reg packet_read,packet_state;
  reg [31:0] raw_index,packet_mask,packet_token,packet_remainder,packet_product;
  reg [6:0] packet_group,packet_head;
  reg [3:0] packet_shift;
  reg [511:0] command_q;
  reg recurrent,causal,masked;
  reg [31:0] nt,nk,kd,vd,heads,kv_heads,head,kv_head,group_size,group_index;
  reg [3:0] key_shift,value_shift;
  integer dimension_bit,ratio_bit;
  reg ratio_supported;
  reg [31:0] selected_group_size;
  always @* begin
    ratio_supported=0;selected_group_size=0;
    for(integer r=0;r<7;r=r+1) begin
      if(kv_heads!=0 && heads==({1'b0,kv_heads}<<r)) begin
        ratio_supported=1;selected_group_size=32'b1<<r;
      end
    end
  end
  wire [31:0] src0=command_q[128+:32],src1=command_q[160+:32],src2=command_q[192+:32];
  wire [31:0] src3=command_q[224+:32],src4=command_q[256+:32];
  wire [31:0] dst0=command_q[64+:32],dst1=command_q[96+:32];
  wire acr,ace,arv,apr,aov,aol,adone,afault,dcr,dce,drv,dpr,dov,dos,dol,ddone,dfault;
  wire [1:0] art;
  wire [2:0] drt;
  wire [31:0] ari,aoi,aod,dri,doi,dod;
  wire [3:0] afc,dfc;
  wire rv=recurrent ? drv : arv;
  wire ov=recurrent ? dov : aov;
  wire [31:0] ri=recurrent ? dri : ari;
  wire [31:0] oi=recurrent ? doi : aoi;
  wire [31:0] od=recurrent ? dod : aod;
  wire pr=recurrent ? dpr : apr;
  wire read_accepted=state==RUN && io_state==IO_IDLE && rv;
  wire write_committed=state==RUN && io_state==IO_WRITE && memory_response_valid && !memory_response_error;
  wire response_to_engine=state==RUN && io_state==IO_READ && memory_response_valid;
  assign command_ready=rst_n && state==IDLE;
  assign completion_valid=rst_n && (state==COMPLETE||state==FAILED);
  assign completion_error=state==FAILED;
  assign memory_valid=rst_n && state==RUN && io_state==IO_ISSUE;
  assign memory_response_ready=rst_n && state==RUN && ((io_state==IO_READ&&pr)||io_state==IO_WRITE);
  openjev_attention attention(
    clk,rst_n,state==LAUNCH&&!recurrent,acr,ace,nt,nk,kd,32'd0,causal,masked,
    arv,read_accepted&&!recurrent,art,ari,response_to_engine&&!recurrent,apr,
    memory_response_data,memory_response_error,
    aov,write_committed&&!recurrent,aoi,aod,aol,adone,afault,afc);
  openjev_gated_delta recurrence(
    clk,rst_n,state==LAUNCH&&recurrent,dcr,dce,nt,kd,vd,1'b0,1'b0,
    drv,read_accepted&&recurrent,drt,dri,response_to_engine&&recurrent,dpr,
    memory_response_data,memory_response_error,
    dov,write_committed&&recurrent,dos,doi,dod,dol,ddone,dfault,dfc);
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;io_state<=IO_IDLE;command_q<=0;completion_tag<=0;recurrent<=0;
      packet_read<=0;packet_state<=0;raw_index<=0;packet_mask<=0;packet_token<=0;
      packet_remainder<=0;packet_product<=0;packet_group<=0;packet_head<=0;packet_shift<=0;
      memory_write<=0;memory_tensor<=0;memory_index<=0;memory_data<=0;
      causal<=0;masked<=0;nt<=0;nk<=0;kd<=0;vd<=0;heads<=0;kv_heads<=0;
      head<=0;kv_head<=0;group_size<=0;group_index<=0;key_shift<=0;value_shift<=0;
    end else begin
      if(state==RUN) begin
        case(io_state)
          IO_IDLE: if(rv||ov) begin
            packet_read<=rv;packet_state<=!rv&&recurrent&&dos;raw_index<=rv ? ri : oi;
            memory_write<=!rv;memory_data<=od;packet_group<=heads[6:0];packet_head<=head[6:0];
            packet_shift<=value_shift;packet_mask<=vd-1;memory_tensor<=dst0;
            if(rv) begin
              if(recurrent) case(drt)
                0: begin memory_tensor<=src0;packet_shift<=key_shift;packet_mask<=kd-1;end
                1: begin memory_tensor<=src1;packet_shift<=key_shift;packet_mask<=kd-1;end
                2: memory_tensor<=src2;
                4: begin memory_tensor<=src3;packet_shift<=0;packet_mask<=0;end
                5: begin memory_tensor<=src4;packet_shift<=0;packet_mask<=0;end
                default: state<=FAILED;
              endcase
              else begin
                packet_shift<=key_shift;packet_mask<=kd-1;
                case(art)
                  0: memory_tensor<=src0;
                  1: begin memory_tensor<=src1;packet_group<=kv_heads[6:0];packet_head<=kv_head[6:0];end
                  2: begin memory_tensor<=src2;packet_group<=kv_heads[6:0];packet_head<=kv_head[6:0];end
                  3: begin memory_tensor<=src3;packet_shift<=0;packet_mask<=0;packet_group<=1;packet_head<=0;end
                endcase
              end
            end else if(recurrent&&dos) memory_tensor<=dst1;
            io_state<=IO_INDEX;
          end
          IO_INDEX: begin packet_token<=raw_index>>packet_shift;packet_remainder<=raw_index&packet_mask;io_state<=IO_MULT;end
          IO_MULT: begin packet_product<=packet_token[19:0]*packet_group;io_state<=IO_MAP;end
          IO_MAP: begin
            memory_index<=packet_state ? (head<<(key_shift+value_shift))|raw_index : ((packet_product+packet_head)<<packet_shift)|packet_remainder;
            io_state<=IO_ISSUE;
          end
          IO_ISSUE: if(memory_ready) io_state<=packet_read ? IO_READ : IO_WRITE;
          default: ;
        endcase
        if(memory_response_valid&&memory_response_ready) begin
          io_state<=IO_IDLE;
          if(memory_response_error) state<=FAILED;
        end
      end
      case(state)
        IDLE: if(command_valid) begin
          command_q<=command_data;completion_tag<=command_data[32+:32];
          recurrent<=command_data[7:0]==23;nt<=command_data[320+:32];
          if(command_data[7:0]==23) begin
            heads<=command_data[352+:32];kv_heads<=command_data[352+:32];
            kd<=command_data[384+:32];vd<=command_data[416+:32];nk<=command_data[320+:32];
          end else begin
            nk<=command_data[352+:32];kd<=command_data[384+:32];vd<=command_data[384+:32];
            heads<=command_data[416+:32];kv_heads<=command_data[448+:32];
          end
          causal<=command_data[8];masked<=command_data[9];
          head<=0;kv_head<=0;group_index<=0;io_state<=IO_IDLE;state<=CHECK;
        end
        CHECK: begin
          for(dimension_bit=0;dimension_bit<9;dimension_bit=dimension_bit+1) begin
            if(kd==(32'b1<<dimension_bit)) key_shift<=dimension_bit;
            if(vd==(32'b1<<dimension_bit)) value_shift<=dimension_bit;
          end
          if((command_q[7:0]!=22&&command_q[7:0]!=23) || command_q[31:10]!=0 ||
             (kd&(kd-1))!=0||(vd&(vd-1))!=0||nt==0||nt>4096||nk==0||nk>4096||kd==0||vd==0||heads==0||heads>64||
             kv_heads==0||kv_heads>heads||!ratio_supported ||
             kd>(recurrent ? 128 : 256)||vd>(recurrent ? 128 : 256) ||
             dst0==32'hffffffff||src0==32'hffffffff||src1==32'hffffffff||src2==32'hffffffff||
             (recurrent && (command_q[9:8]!=3||src3==32'hffffffff||src4==32'hffffffff||dst1==32'hffffffff))||
             (!recurrent && ((masked&&src3==32'hffffffff)||(causal&&nt!=nk))))
            state<=FAILED;
          else begin group_size<=selected_group_size;state<=LAUNCH;end
        end
        LAUNCH: if(recurrent ? dcr : acr) state<=RUN;
        RUN: begin
          if(afault||dfault||ace||dce) state<=FAILED;
          else if(recurrent ? ddone : adone) begin
            if(io_state!=IO_IDLE) state<=FAILED;
            else if(head==heads-1) state<=COMPLETE;
            else begin
              head<=head+1;
              if(group_index==group_size-1) begin kv_head<=kv_head+1;group_index<=0;end
              else group_index<=group_index+1;
              state<=LAUNCH;
            end
          end
        end
        COMPLETE: if(completion_ready) state<=IDLE;
        FAILED: state<=FAILED;
        default: state<=FAILED;
      endcase
    end
  end
endmodule
