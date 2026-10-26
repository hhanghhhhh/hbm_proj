/*
Module Name : SPI
Author: hyn
Function: One package spi transmit

Parameter Input:
SYSCLKFREQ: System clk input (Hz)
UARTBAUD: Spi speed (Hz)
MAXLENGTH: Spi one package maxlength (bits)
READDELAY: High speed transmit cause hardware delay, delay (n-1) sysclk period before read
MODE = 0: CPOL = 0 CPHA = 0 clock idle low, read data at the first edge
MODE = 1: CPOL = 0 CPHA = 1 clock idle low, read data at the second edge
MODE = 2: CPOL = 1 CPHA = 0 clock idle high, read data at the first edge
MODE = 3: CPOL = 1 CPHA = 1 clock idle high, read data at the second edge

Input Port:
i_startflag: High pulse start spi transmit
i_translength: Current transmit package bits num
i_sendpackage: Spi send data. Send from high bit

Output Port:
o_doneflag: Send one clk high pulse when spi transmit over
o_recpackage: Spi read data. First receive store in high bit

Physical Port:
spi_clk
spi_cs
spi_mosi
spi_miso
*/

module SPI #
(
	parameter SYSCLKFREQ		= 100000000,
	parameter UARTBAUD			= 100000,
	parameter MAXLENGTH			= 16, 
	parameter READDELAY			= 0,
    parameter MODE				= 0
)
(
	input               			clk         	,  //system clk
    input               			rst_n       	,  //system reset
    
    input							i_startflag		,
    output	reg						o_doneflag		,
    input		[7:0]				i_translength	,
    input		[MAXLENGTH-1:0]		i_sendpackage	,
    output	reg	[MAXLENGTH-1:0]		o_recpackage	,
    
    output	reg						spi_clk			,
    output	reg						spi_cs			,
    output	reg						spi_mosi		,
    input							spi_miso
);

parameter CLKCNTMAX		= SYSCLKFREQ/UARTBAUD;
parameter BEFOREDELAY	= 16'd0;
parameter ENDDELAY		= 16'd0;

parameter	STATE_IDLE			=	2'd0;
parameter	STATE_DELAYBEFORE	=	2'd1;
parameter	STATE_WORK			=	2'd2;
parameter	STATE_DELAY			=	2'd3;

reg	[1:0]	Spi_State;
reg	[31:0]	ClkCnt;
reg	[15:0]	DelayCnt;
reg	[31:0]	ReadCnt;	// synthesis keep

reg	[31:0]	BitCnt;
reg			FirstFlag;

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    	ClkCnt <= 32'd0;
    else if(Spi_State == STATE_WORK)
    begin
    	if(ClkCnt < CLKCNTMAX-1)
        	ClkCnt <= ClkCnt + 1'b1;
        else
        	ClkCnt <= 32'd0;
    end
    else
    	ClkCnt <= 32'd0;
end

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    	ReadCnt <= 32'd0;
    else if(Spi_State == STATE_WORK)
    begin
    	if(ClkCnt == READDELAY-1)
        	ReadCnt <= 32'd0;
        else
        	ReadCnt <= ReadCnt + 32'd1;
    end
    else
    	ReadCnt <= 32'd0;
end

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
    	Spi_State <= STATE_IDLE;
		DelayCnt <= 16'd0;
        o_doneflag <= 1'b0;
		spi_cs <= 1'b1;
    end
    else if(o_doneflag == 1'b1)
    	o_doneflag <= 1'b0;
    else
    begin
    	case(Spi_State)
        
        	STATE_IDLE:
            begin
				spi_cs <= 1'b1;
            	if(i_startflag == 1'b1)
                	Spi_State <= STATE_DELAYBEFORE;
                else
                	Spi_State <= STATE_IDLE;
            end

			STATE_DELAYBEFORE:
            begin
            	if(DelayCnt < BEFOREDELAY)
				begin
                	DelayCnt <= DelayCnt + 16'd1;
                end
				else
                begin
                	DelayCnt <= 16'd0;
                    Spi_State <= STATE_WORK;
                end
            end
            
            STATE_WORK:
            begin
				spi_cs <= 1'b0;
            	if(BitCnt > i_translength)
                begin
                	Spi_State <= STATE_DELAY;  
                end
                else
                	Spi_State <= STATE_WORK;
            end

			STATE_DELAY:
            begin
            	if(DelayCnt < ENDDELAY)
				begin
                	DelayCnt <= DelayCnt + 16'd1;
                end
				else
                begin
                	DelayCnt <= 16'd0;
					o_doneflag <= 1'b1;
                    Spi_State <= STATE_IDLE;
                end
            end
        
        endcase
    end
end

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
    	BitCnt <= 32'd0;
        spi_clk <= 1'b0;
        spi_mosi <= 1'b0;
		FirstFlag <= 1'b0;
    end
    else
    begin
    	if(Spi_State == STATE_IDLE)
        begin
        	BitCnt <= 32'd0;
			FirstFlag <= 1'b0;
			if(MODE == 2'd0 || MODE == 2'd1)
			begin
            	spi_clk <= 1'b0;
            end
            else if(MODE == 2'd2 || MODE == 2'd3)
            begin
            	spi_clk <= 1'b1;
            end
        	spi_mosi <= 1'b1;
        end
        else
        begin
			if(ClkCnt == CLKCNTMAX/2-1)
			begin
                if(FirstFlag == 1'b0)
                begin
                	FirstFlag <= 1'b1;
					if(MODE == 2'd1 || MODE == 2'd3)
					begin
                    	spi_clk <= ~spi_clk;
                    end
                end
                else
                begin
                	spi_clk <= ~spi_clk;
                end
				BitCnt <= BitCnt + 1'b1;
				if(BitCnt < i_translength)
					spi_mosi <= i_sendpackage[MAXLENGTH-1-BitCnt];
            end
            else if(ClkCnt == CLKCNTMAX-1)
			begin
				if(BitCnt < i_translength+1)
				begin
            		spi_clk <= ~spi_clk;
					if(READDELAY == 0)
						o_recpackage <= {o_recpackage[MAXLENGTH-2:0],spi_miso};
				end
            end
        end
    end
end

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
    
    end
    else if(ReadCnt == CLKCNTMAX-1)
    begin
		if(READDELAY > 0)
    		o_recpackage <= {o_recpackage[MAXLENGTH-2:0],spi_miso};
    end
end

endmodule
