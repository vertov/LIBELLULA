
task automatic fail_msg(input [1023:0] msg);
    $display("FAIL: %s", msg);
    $finish_and_return(1);
endtask

task automatic pass();
    $display("PASS");
    $finish;
endtask
