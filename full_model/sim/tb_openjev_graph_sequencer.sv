module tb_openjev_graph_sequencer;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,load_valid=0,start=0,dispatch_ready=0,completion_valid=0,completion_error=0;
    reg [31:0] load_index=0,program_length=3,tensor_count=10,completion_tag=0;
    reg [511:0] load_data=0;
    wire load_ready,dispatch_valid,done,fault;
    wire [3:0] fault_code;
    wire [511:0] dispatch_data;
    integer count=0;
    openjev_graph_sequencer #(.MAX_INSTRUCTIONS(8),.CAPABILITIES((256'b1<<22)|(256'b1<<23)),.WATCHDOG_CYCLES(20)) dut(.*);
    function [511:0] command;
        input [7:0] op;
        input [31:0] tag;
        reg [511:0] v;
        reg [31:0] sum;
        integer i;
        begin
            v=0; v[7:0]=op; v[32+:32]=tag;
            for(i=2;i<10;i=i+1) v[i*32+:32]=32'hffffffff;
            if(op!=255) begin v[64+:32]=2; v[128+:32]=0; end
            sum=32'h4f4a5031;
            for(i=0;i<15;i=i+1) sum=sum^v[i*32+:32];
            v[480+:32]=sum; command=v;
        end
    endfunction
    task reset;
        begin
            @(negedge clk); rst_n=0; load_valid=0; start=0;
            dispatch_ready=0; completion_valid=0; completion_error=0;
            repeat(2) @(negedge clk);
            rst_n=1; program_length=3; tensor_count=10;
        end
    endtask
    task load;
        input integer index;
        input [511:0] data;
        begin
            @(negedge clk); load_valid=1; load_index=index; load_data=data;
            @(negedge clk); load_valid=0;
        end
    endtask
    task setup;
        begin reset; load(0,command(22,0)); load(1,command(23,1)); load(2,command(255,2)); end
    endtask
    task launch;
        begin @(negedge clk);start=1;@(negedge clk);start=0;end
    endtask
    task expect_fault;
        input [3:0] code;
        integer j;
        begin
            j=0;
            while(!fault && j<100) begin @(negedge clk);j=j+1;end
            if(!fault || fault_code!=code || done) $fatal(1,"fault mismatch %d",fault_code);
            repeat(3) @(negedge clk);
            if(!fault || dispatch_valid || load_ready) $fatal(1,"fault not sticky");
            count=count+1;
        end
    endtask
    task complete;
        input [31:0] tag;
        begin
            wait(dispatch_valid); @(negedge clk);
            if(dispatch_data[32+:32]!=tag) $fatal(1,"dispatch order");
            repeat(3) @(negedge clk);
            dispatch_ready=1; @(negedge clk);dispatch_ready=0;
            repeat(3) @(negedge clk);
            completion_tag=tag;completion_valid=1;
            @(negedge clk);completion_valid=0;
        end
    endtask
    initial begin
        setup;launch;complete(0);complete(1);wait(done);count=count+1;
        setup;load(1,command(1,1));launch;expect_fault(2);
        setup;load(1,command(23,1)^512'b1);launch;expect_fault(2);
        setup;load(1,command(23,0));launch;expect_fault(2);
        setup;load(1,command(255,1));launch;expect_fault(2);
        setup;load(2,command(22,2));launch;expect_fault(2);
        reset;load(0,command(22,0));launch;expect_fault(2);
        setup;tensor_count=2;launch;expect_fault(2);
        setup;program_length=0;launch;expect_fault(1);
        setup;launch;expect_fault(4);
        setup;launch;wait(dispatch_valid);@(negedge clk);dispatch_ready=1;
        @(negedge clk);dispatch_ready=0;expect_fault(4);
        setup;launch;wait(dispatch_valid);@(negedge clk);dispatch_ready=1;
        @(negedge clk);dispatch_ready=0;completion_valid=1;completion_tag=9;expect_fault(3);
        setup;launch;wait(dispatch_valid);@(negedge clk);dispatch_ready=1;
        @(negedge clk);dispatch_ready=0;completion_valid=1;completion_tag=0;completion_error=1;expect_fault(3);
        setup;launch;wait(dispatch_valid);@(negedge clk);completion_valid=1;expect_fault(3);
        reset;
        if(fault || dispatch_valid) $fatal(1,"reset failed");
        $display("PASS graph sequencer: %0d scenarios plus reset",count);
        $finish;
    end
    initial begin #100000; $fatal(1,"test timeout");end
endmodule
