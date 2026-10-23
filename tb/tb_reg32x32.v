module tb_top_processor;

    reg Clock;
    reg rst;
    reg start;
    
    top_processor my_pro (
        .Clock(Clock),
        .rst(rst),
        .start(start)
        );
        
    always #5 Clock = ~Clock;
    
    initial begin
        Clock = 0;
        rst = 1;
        start = 0;

        #10;
        rst = 0;

        $readmemh("init.dat", my_pro.my_rf.regfile);

        start = 1;
        #10;
        start = 0;
        #220;
        $finish;
     end
     
endmodule