`timescale 1ns/1ps
// Tensor ABI v1 address translation. Restoring division avoids a combinational
// variable-divisor datapath. Descriptors and root descriptors are latched.
module openjev_tensor_address(
  input wire clk,rst_n,request_valid,
  output wire request_ready,
  input wire [1023:0] descriptor,root_descriptor,
  input wire [31:0] element_index,
  input wire request_write,
  output wire response_valid,
  input wire response_ready,
  output reg response_error,
  output reg [31:0] base_address,bank_extent,logical_bytes,byte_offset,
  output reg [2:0] element_bytes
);
  localparam IDLE=0,CHECK_AXIS=1,DIV_INIT=2,DIVIDE=3,ACCUMULATE=4,FINISH=5,RESULT=6,AXIS_PRODUCT=7,AXIS_SAVE=8,ADDRESS_SAVE=9;
  reg [3:0] state;
  reg [1023:0] tensor_q,root_q;
  reg [31:0] index_q,remaining_index,quotient,divisor;
  reg [32:0] remainder_value;
  wire [32:0] shifted_remainder={remainder_value[31:0],quotient[31]};
  reg [63:0] elements,span,address_sum,span_product,index_product;
  reg [31:0] dimension_q,stride_q,span_factor;
  reg [2:0] rank_q,axis;
  reg [5:0] bit_count;
  reg write_q;
  wire [31:0] dimension=tensor_q[(8+axis)*32+:32];
  wire [31:0] stride=tensor_q[(12+axis)*32+:32];
  wire [31:0] alignment_mask=element_bytes-1;
  assign request_ready=rst_n && state==IDLE;
  assign response_valid=rst_n && state==RESULT;
  task reject;
    begin response_error<=1;state<=RESULT;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;tensor_q<=0;root_q<=0;index_q<=0;remaining_index<=0;
      quotient<=0;divisor<=0;remainder_value<=0;elements<=0;span<=0;address_sum<=0;
      span_product<=0;index_product<=0;dimension_q<=0;stride_q<=0;span_factor<=0;rank_q<=0;axis<=0;bit_count<=0;write_q<=0;response_error<=0;
      base_address<=0;bank_extent<=0;logical_bytes<=0;byte_offset<=0;element_bytes<=0;
    end else case(state)
      IDLE: if(request_valid) begin
        tensor_q<=descriptor;root_q<=root_descriptor;index_q<=element_index;
        remaining_index<=element_index;write_q<=request_write;
        base_address<=root_descriptor[128+:32];logical_bytes<=root_descriptor[160+:32];
        bank_extent<=root_descriptor[512+:32];byte_offset<=0;response_error<=0;
        element_bytes<=descriptor[32+:32]==0 ? 1 : descriptor[32+:32]==1 ? 2 : 4;
        rank_q<=descriptor[96+:32];axis<=0;elements<=1;
        span<={32'b0,descriptor[224+:32]};
        address_sum<={32'b0,descriptor[224+:32]};
        if(descriptor[96+:32]<1 || descriptor[96+:32]>4 || descriptor[32+:32]>3 ||
           descriptor[64+:32]>3 || root_descriptor[64+:32]>2 ||
           descriptor[192+:32]!=root_descriptor[0+:32] ||
           root_descriptor[192+:32]!=root_descriptor[0+:32] ||
           root_descriptor[224+:32]!=0 ||
           descriptor[32+:32]!=root_descriptor[32+:32] ||
           descriptor[128+:32]!=root_descriptor[128+:32] ||
           descriptor[512+:32]!=root_descriptor[512+:32] ||
           (descriptor[64+:32]!=3 && (descriptor[0+:32]!=root_descriptor[0+:32] || descriptor[64+:32]!=root_descriptor[64+:32])) ||
           (request_write && (descriptor[64+:32]!=2 || descriptor[0+:32]!=root_descriptor[0+:32])))
          reject;
        else state<=CHECK_AXIS;
      end
      CHECK_AXIS: begin
        if(dimension==0 || stride==0 || (stride&alignment_mask)!=0 ||
           (tensor_q[224+:32]&alignment_mask)!=0 || elements>32'hffffffff || span>32'hffffffff)
          reject;
        else begin
          dimension_q<=dimension;stride_q<=stride;span_factor<=dimension-1;
          state<=AXIS_PRODUCT;
        end
      end
      AXIS_PRODUCT: begin
        elements<=elements[31:0]*dimension_q;
        span_product<=span_factor*stride_q;
        state<=AXIS_SAVE;
      end
      AXIS_SAVE: begin
        span<=span+span_product;
        if(axis==rank_q-1) begin axis<=rank_q-1;state<=DIV_INIT;end
        else begin axis<=axis+1;state<=CHECK_AXIS;end
      end
      DIV_INIT: begin
        if(elements>32'hffffffff || index_q>=elements ||
           (elements<<(element_bytes==4 ? 2 : element_bytes==2 ? 1 : 0))!={32'b0,tensor_q[160+:32]} ||
           span+element_bytes>{32'b0,logical_bytes}) reject;
        else begin
          quotient<=remaining_index;divisor<=dimension;remainder_value<=0;bit_count<=0;
          state<=DIVIDE;
        end
      end
      DIVIDE: begin
        if(shifted_remainder>={1'b0,divisor}) begin
          remainder_value<=shifted_remainder-{1'b0,divisor};
          quotient<={quotient[30:0],1'b1};
        end else begin remainder_value<=shifted_remainder;quotient<={quotient[30:0],1'b0};end
        if(bit_count==31) state<=ACCUMULATE;
        else bit_count<=bit_count+1;
      end
      ACCUMULATE: begin
        index_product<=remainder_value[31:0]*stride;
        remaining_index<=quotient;state<=ADDRESS_SAVE;
      end
      ADDRESS_SAVE: begin
        address_sum<=address_sum+index_product;
        if(axis==0) state<=FINISH;
        else begin axis<=axis-1;state<=DIV_INIT;end
      end
      FINISH: begin
        if(address_sum+element_bytes>{32'b0,logical_bytes} || address_sum>32'hffffffff || remaining_index!=0)
          reject;
        else begin byte_offset<=address_sum[31:0];state<=RESULT;end
      end
      RESULT: if(response_ready) state<=IDLE;
      default: reject;
    endcase
  end
endmodule
