`timescale 1ns / 1ps

// Active-low reset: asynchronous assertion while PLL is unlocked,
// synchronous release after four destination-clock edges.
module reset_release_sync (
    input  wire clk,
    input  wire async_ready,
    output wire rst_n
);

    (* async_reg = "true" *) reg [3:0] sync_ff;

    always @(posedge clk or negedge async_ready) begin
        if (!async_ready)
            sync_ff <= 4'b0000;
        else
            sync_ff <= {sync_ff[2:0], 1'b1};
    end

    assign rst_n = sync_ff[3];

endmodule
