// Tensor-program v1 fetch, whole-program preflight, and serialized dispatch.
// Engine completion must follow the final committed HBM write.
module openjev_graph_sequencer #(
    parameter integer MAX_INSTRUCTIONS=4096,
    parameter [255:0] CAPABILITIES=256'b0,
    parameter [63:0] WATCHDOG_CYCLES=64'd100000000000
)(
    input wire clk, rst_n,
    input wire load_valid,
    output wire load_ready,
    input wire [31:0] load_index,
    input wire [511:0] load_data,
    input wire start,
    input wire [31:0] program_length, tensor_count,
    output wire dispatch_valid,
    input wire dispatch_ready,
    output wire [511:0] dispatch_data,
    input wire completion_valid,
    input wire [31:0] completion_tag,
    input wire completion_error,
    output reg done, fault,
    output reg [3:0] fault_code
);
    localparam IDLE=0, PREFLIGHT=1, FETCH=2, DISPATCH=3, WAIT_ENGINE=4, FAILED=5,
               READ_PREFLIGHT=6, READ_EXECUTION=7, LATCH_PREFLIGHT=8,
               LATCH_EXECUTION=9, CHECK_PREFLIGHT=10;
    localparam ADDRESS_WIDTH=MAX_INSTRUCTIONS>1 ? $clog2(MAX_INSTRUCTIONS) : 1;
    reg [3:0] state;
    (* ram_style="block" *) reg [511:0] instructions [0:MAX_INSTRUCTIONS-1];
    reg [MAX_INSTRUCTIONS-1:0] loaded;
    reg [ADDRESS_WIDTH-1:0] pc;
    reg [31:0] length_q, tensors_q;
    reg [63:0] watchdog;
    reg [511:0] command_q;
    reg [31:0] checksum;
    reg valid_command;
    integer i;
    reg [511:0] candidate;
    reg [511:0] memory_word;
    reg checked_valid, checked_last;
    wire [7:0] opcode = candidate[7:0];
    assign load_ready = state==IDLE && !start && load_index<MAX_INSTRUCTIONS;
    assign dispatch_valid = state==DISPATCH && !fault;
    assign dispatch_data = command_q;
    always @* begin
        checksum=32'h4f4a5031;
        for(i=0;i<15;i=i+1) checksum=checksum ^ candidate[i*32+:32];
        valid_command=(checksum==candidate[480+:32]) && candidate[32+:32]==pc;
        if(opcode==255) begin
            valid_command=valid_command && pc==length_q-1 && candidate[31:8]==0;
            for(i=2;i<10;i=i+1)
                if(candidate[i*32+:32]!=32'hffffffff) valid_command=0;
            for(i=10;i<15;i=i+1)
                if(candidate[i*32+:32]!=0) valid_command=0;
        end else begin
            valid_command=valid_command && pc<length_q-1 && CAPABILITIES[opcode];
            if(candidate[64+:32]==32'hffffffff) valid_command=0;
            for(i=2;i<10;i=i+1)
                if(candidate[i*32+:32]!=32'hffffffff && candidate[i*32+:32]>=tensors_q)
                    valid_command=0;
        end
    end
    task fail;
        input [3:0] code;
        begin fault<=1; fault_code<=code; state<=FAILED; end
    endtask
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; loaded<=0; pc<=0; length_q<=0; tensors_q<=0;
            watchdog<=0; command_q<=0; candidate<=0; memory_word<=0;
            checked_valid<=0; checked_last<=0; done<=0; fault<=0; fault_code<=0;
        end else begin
            done<=0;
            if(state==DISPATCH || state==WAIT_ENGINE) begin
                if(watchdog>=WATCHDOG_CYCLES-1) fail(4'd4);
                else watchdog<=watchdog+1;
            end
            if(!((state==DISPATCH || state==WAIT_ENGINE) && watchdog>=WATCHDOG_CYCLES-1)) begin
                case(state)
                    IDLE: begin
                        if(load_valid && load_ready) begin
                            instructions[load_index]<=load_data;
                            loaded[load_index]<=1;
                        end
                        if(start) begin
                            if(program_length==0 || program_length>MAX_INSTRUCTIONS || tensor_count==0)
                                fail(4'd1);
                            else begin
                                pc<=0; length_q<=program_length; tensors_q<=tensor_count;
                                state<=READ_PREFLIGHT;
                            end
                        end
                    end
                    READ_PREFLIGHT: begin memory_word<=instructions[pc];state<=LATCH_PREFLIGHT;end
                    READ_EXECUTION: begin memory_word<=instructions[pc];state<=LATCH_EXECUTION;end
                    LATCH_PREFLIGHT: begin candidate<=memory_word;state<=CHECK_PREFLIGHT;end
                    LATCH_EXECUTION: begin candidate<=memory_word;state<=FETCH;end
                    CHECK_PREFLIGHT: begin
                        checked_valid<=loaded[pc] && valid_command;
                        checked_last<=pc==length_q-1;
                        state<=PREFLIGHT;
                    end
                    PREFLIGHT: begin
                        if(!checked_valid) fail(4'd2);
                        else if(checked_last) begin pc<=0; state<=READ_EXECUTION; end
                        else begin pc<=pc+1;state<=READ_PREFLIGHT;end
                    end
                    FETCH: begin
                        if(candidate[7:0]==255) begin done<=1; state<=IDLE; end
                        else begin command_q<=candidate; watchdog<=0; state<=DISPATCH; end
                    end
                    DISPATCH: begin
                        // Completion cannot legally precede an accepted command.
                        if(completion_valid) fail(4'd3);
                        else if(dispatch_ready) state<=WAIT_ENGINE;
                    end
                    WAIT_ENGINE: begin
                        if(completion_valid) begin
                            if(completion_error || completion_tag!=pc) fail(4'd3);
                            else begin pc<=pc+1; state<=READ_EXECUTION; end
                        end
                    end
                    FAILED: state<=FAILED;
                    default: fail(4'd5);
                endcase
            end
        end
    end
endmodule
