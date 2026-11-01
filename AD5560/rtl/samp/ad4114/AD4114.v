`include "AD4114_H.v"

module AD4114 #
(
	parameter CHANNELENABLE	=	16'hffff,
    parameter ENHFILTEREN	=	`FILTERSET_ENHFILTER_DIS,
    parameter ENHFILTER		=	`FILTERSET_EBHFILTER_25SPS,
    parameter FILTERORDER	=	`FILTERSET_ORDER_SINC5_SINC1,
    parameter FILTERODR		=	`FILTERSET_ODR_20_01SPS
)
(
    input               clk         ,  //system clk
    input               rst_n       ,  //system reset
    
    input				i_readflag	,
    output	reg			o_adcover	,
    
    output	reg	[23:0]	o_result	,
    output	reg	[3:0]	o_channel	,
	output	reg			o_doneflag	,

	output	wire		o_err		,
    
    output	wire		o_spi_clk	,
    output	wire		o_spi_cs	,
    output	wire		o_spi_mosi	,
    input	wire		i_spi_miso
);


parameter SYSCLKFREQ		= 100000000;
parameter UARTBAUD			= 500000;
parameter MAXLENGTH			= 64;
parameter RSTDELAY			= 25000;//500*SYSCLKFREQ/1000000;	//500us

parameter	STATE_RST				=	8'd0;
parameter	STATE_RST_DELAY			=	8'd1;
parameter	STATE_IDCHECK			=	8'd2;
parameter	STATE_CONFIGCHANNEL		=	8'd3;
parameter	STATE_CONFIGSETUP		=	8'd4;
parameter	STATE_CONFIGFILTER		=	8'd5;
parameter	STATE_CONFIGADCMODE		=	8'd6;
parameter	STATE_CONFIGINTERFACE	=	8'd7;
parameter	STATE_IDLE				=	8'd8;
parameter	STATE_READSTART			=	8'd9;
parameter	STATE_READ				=	8'd10;
parameter	STATE_READOVER			=	8'd11;
parameter	STATE_CRCSTART			=	8'd12;
parameter	STATE_CRCCAL			=	8'd13;
parameter	STATE_CRCRESULT			=	8'd14;
parameter	STATE_WAITSPIOVER		=	8'd15;


reg		[7:0]				AdcState;
reg		[7:0]				JumpState;

reg							Spi_StartFlag;
wire						Spi_DoneFlag;
reg		[7:0]				Spi_Translength;
reg		[MAXLENGTH-1:0]		Spi_SendPackage;
wire	[MAXLENGTH-1:0]		Spi_RecPackage;		// synthesis keep
wire						Cs_Spi;
reg							Cs_Continueread;
reg		[15:0]				RstDelaycnt;
reg		[15:0]				AdChannelRead;
reg							Ad_RstFlag;
reg							Spi_Misolast;
reg							Spi_Ready;
reg							Spi_ReadFlag;
reg		[7:0]				Config_ChannelCnt;
wire	[9:0]				Config_ChannelSet[15:0];
reg		[5:0]				Config_ChannelAdd;
reg		[7:0]				AdcCrcCnt;

reg		[20:0]				TestDelayCnt;
reg							Spi_Readywirelast;
reg							Spi_Readywire;

reg							CsState;

reg		[7:0]	AdcCrc_Din;	// synthesis keep
reg				AdcCrc_En;		// synthesis keep
reg				AdcCrc_End;	// synthesis keep
reg				AdcCrc_Start;	// synthesis keep
reg				AdcCrc_Rst;	// synthesis keep
wire	[7:0]	AdcCrc_Out;	// synthesis keep
wire			AdcCrc_Vld;	// synthesis keep


assign	o_spi_cs = (CsState == 1'b1) ? Cs_Continueread : Cs_Spi;
assign	o_err = (JumpState > STATE_IDCHECK) ? 1'b0 : 1'b1;

assign	Config_ChannelSet[0]	= `CHANNELSET_INPUT_VIN0VCOM;
assign	Config_ChannelSet[1]	= `CHANNELSET_INPUT_VIN1VCOM;
assign	Config_ChannelSet[2]	= `CHANNELSET_INPUT_VIN2VCOM;
assign	Config_ChannelSet[3]	= `CHANNELSET_INPUT_VIN3VCOM;
assign	Config_ChannelSet[4]	= `CHANNELSET_INPUT_VIN4VCOM;
assign	Config_ChannelSet[5]	= `CHANNELSET_INPUT_VIN5VCOM;
assign	Config_ChannelSet[6]	= `CHANNELSET_INPUT_VIN6VCOM;
assign	Config_ChannelSet[7]	= `CHANNELSET_INPUT_VIN7VCOM;
assign	Config_ChannelSet[8]	= `CHANNELSET_INPUT_VIN8VCOM;
assign	Config_ChannelSet[9]	= `CHANNELSET_INPUT_VIN9VCOM;
assign	Config_ChannelSet[10]	= `CHANNELSET_INPUT_VIN10VCOM;
assign	Config_ChannelSet[11]	= `CHANNELSET_INPUT_VIN11VCOM;
assign	Config_ChannelSet[12]	= `CHANNELSET_INPUT_VIN12VCOM;
assign	Config_ChannelSet[13]	= `CHANNELSET_INPUT_VIN13VCOM;
assign	Config_ChannelSet[14]	= `CHANNELSET_INPUT_VIN14VCOM;
assign	Config_ChannelSet[15]	= `CHANNELSET_INPUT_VIN15VCOM;


always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
        Spi_Readywire <= 1'b0;
		Spi_Readywirelast <= 1'b0;
    end
    else
    begin
    	Spi_Readywire <= i_spi_miso;
        Spi_Readywirelast <= Spi_Readywire;
    end
end

reg		[31:0]	TestReadyCnt;	// synthesis keep
reg				TestReadyDelay;	// synthesis keep

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
    	TestReadyCnt <= 32'd0;
        TestReadyDelay <= 1'b0;
    end
    else
    begin
    	if(Spi_ReadFlag == 1'b1 && Spi_Ready == 1'b0)
        begin
        	if(TestReadyCnt < 32'd500000)
            begin
            	TestReadyCnt <= TestReadyCnt + 32'd1;
            end
            else
            begin
            	TestReadyDelay <= 1'b1;
            end
        end
        else
        begin
        	TestReadyCnt <= 32'd0;
        end
    end
end

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
		TestDelayCnt <= 21'd0;
        Spi_Ready <= 1'b0;
    end
    else if(Spi_ReadFlag == 1'b0)
	begin
    	Spi_Ready <= 1'b0;
		TestDelayCnt <= 21'd0;
	end
    else
    begin
/*
		if(Spi_Readywire == 1'b0 && Spi_Readywirelast == 1'b1)
        begin
        	Spi_Ready <= 1'b1;
        end
*/

    	if(i_spi_miso == 1'b0)
		begin
        	if(TestDelayCnt <= 21'd100)
            	TestDelayCnt <= TestDelayCnt + 21'd1;
            else
            begin
            	Spi_Ready <= 1'b1;
            end
        end
        else
        begin
        	TestDelayCnt <= 21'd0;
        end

    end
end

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
        Config_ChannelAdd <= 6'd0;
    end
    else
    begin
    	Config_ChannelAdd <= `ADDRESS_CHANNEL0 + Config_ChannelCnt;
    end
end

reg				TestInit;// synthesis keep
reg				TestFlag;// synthesis keep
reg		[3:0]	TestChannel;// synthesis keep
reg		[7:0]	TestCnt;// synthesis keep

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n)
    begin
    	AdcState <= STATE_RST;
		JumpState <= STATE_RST;
        Cs_Continueread <= 1'b1;
        Spi_StartFlag <= 1'b0;
        RstDelaycnt <= 16'd0;
        Spi_Translength <= 32'd0;
        Spi_ReadFlag <= 1'b0;
		AdChannelRead <= 16'd0;
		Config_ChannelCnt <= 8'd0;
		o_channel <= 4'd0;
        o_result <= 24'd0;
		o_doneflag <= 1'b0;
		o_adcover <= 1'b0;
		AdcCrcCnt <= 8'd0;
		AdcCrc_Din <= 8'd0;
		AdcCrc_En <= 1'b0;
		AdcCrc_End <= 1'b0;
		AdcCrc_Start <= 1'b0;
		AdcCrc_Rst <= 1'b0;
		CsState <= 1'b0;
		TestCnt <= 8'd0;
    end
    else
    begin
    	case(AdcState)
        	
            STATE_RST:
            begin
				if(i_readflag == 1'b1)
                begin
                Spi_StartFlag <= 1'b1;
                Spi_SendPackage[63:0] <= 64'hffffffffffffffff;
                Spi_Translength <= 32'd64;
				AdcState <= STATE_WAITSPIOVER;
                JumpState <= STATE_RST_DELAY;
                end
            end
            
            STATE_RST_DELAY:
            begin
                if(RstDelaycnt < RSTDELAY)
                    RstDelaycnt <= RstDelaycnt + 1'b1;
                else
                begin
                    RstDelaycnt <= 16'd0;

                    Spi_StartFlag <= 1'b1;
                    Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-24] <= {`READCMD, `ADDRESS_ID, 16'hffff};
                    Spi_Translength <= 32'd24;
					AdcState <= STATE_WAITSPIOVER;
                    JumpState <= STATE_IDCHECK;

					//AdcState <= STATE_CONFIGCHANNEL;
                end
            end
            
            STATE_IDCHECK:
            begin
                if(Spi_RecPackage[15:4] == 12'h30d || Spi_RecPackage[15:0] == 16'h4101)
                    AdcState <= STATE_CONFIGCHANNEL;
				else
                    AdcState <= STATE_RST_DELAY;
            end
            
            STATE_CONFIGCHANNEL:
            begin
				if(Config_ChannelCnt < 8'd16)
				begin
                	Spi_StartFlag <= 1'b1;
					Config_ChannelCnt <= Config_ChannelCnt + 8'd1;
                    Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-24] <= {`WRITECMD, Config_ChannelAdd, CHANNELENABLE[Config_ChannelCnt], `CHANNELSET_SETUPSEL_SETUP0, 2'd0, Config_ChannelSet[Config_ChannelCnt]};
                    Spi_Translength <= 32'd24;
					AdcState <= STATE_WAITSPIOVER;
                    JumpState <= STATE_CONFIGCHANNEL;
                end
                else
                begin
                    Config_ChannelCnt <= 8'd0;
                    AdcState <= STATE_CONFIGSETUP;
                end
			end
                    
            STATE_CONFIGSETUP:
            begin
                Spi_StartFlag <= 1'b1;
                Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-24] <= {`WRITECMD, `ADDRESS_SETUP0, 3'd0, `SETUPSET_CODE_BIPOLAR, `SETUPSET_REFBUFP_EN, `SETUPSET_REFBUFN_EN, `SETUPSET_INBUF_EN, 2'd0, `SETUPSET_REFSEL_INTERNAL, 4'd0};
                Spi_Translength <= 32'd24;
				AdcState <= STATE_WAITSPIOVER;
                JumpState <= STATE_CONFIGFILTER;
            end
                    
            STATE_CONFIGFILTER:
            begin
                Spi_StartFlag <= 1'b1;
                Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-24] <= {`WRITECMD, `ADDRESS_FILTER0, `FILTERSET_SINCMAP_DIS, 3'd0, ENHFILTEREN, ENHFILTER, 1'b0, FILTERORDER, FILTERODR};
                Spi_Translength <= 32'd24;
				AdcState <= STATE_WAITSPIOVER;
                JumpState <= STATE_CONFIGADCMODE;
            end
                    
            STATE_CONFIGADCMODE:
            begin
                Spi_StartFlag <= 1'b1;
                Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-24] <= {`WRITECMD, `ADDRESS_ADCMODE, `ADCSET_REFEN_EN, 1'b0, `ADCSET_SINGLE_DIS, 2'd0, `ADCSET_DELAY_0US, 1'b0, `ADCSET_MODE_CONTINUOUS, `ADCSET_CLKSEL_INOSC, 2'd0};
                Spi_Translength <= 32'd24;
				AdcState <= STATE_WAITSPIOVER;
                JumpState <= STATE_CONFIGINTERFACE;
            end
                    
            STATE_CONFIGINTERFACE:
            begin
                Spi_StartFlag <= 1'b1;
                Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-24] <= {`WRITECMD, `ADDRESS_INTERFACE, 3'd0, `INTERFACESET_ALTSYNC_DIS, `INTERFACESET_IOSTRENGTH_DIS, 2'd0, `INTERFACESET_DOUTRESET_EN, `INTERFACESET_CONTREAD_DIS, `INTERFACESET_DATASTAT_EN, `INTERFACESET_REGCHECK_DIS, 1'b0, `INTERFACESET_CRC_CRC, 1'b0, `INTERFACESET_WL16_24};
                Spi_Translength <= 32'd24;
				AdcState <= STATE_WAITSPIOVER;
                JumpState <= STATE_IDLE;
            end
            
            STATE_IDLE:
            begin
				o_adcover <= 1'b0;
            	Cs_Continueread <= 1'b1;
				o_doneflag <= 1'b0;
				CsState <= 1'b1;
            	if(i_readflag == 1'b1)
				begin
					TestInit <= 1'b0;
					TestFlag <= 1'b0;
            		AdcState <= STATE_READSTART;
					Spi_ReadFlag <= 1'b1;
				end
            end
            
            STATE_READSTART:
            begin
            	Cs_Continueread <= 1'b0;
				o_doneflag <= 1'b0;
				if(AdChannelRead == CHANNELENABLE)
                begin
					TestCnt <= 8'd0;
					o_adcover <= 1'b1;
					AdChannelRead <= 16'd0;
					AdcState <= STATE_IDLE;
				end
                else
                begin
                	if(Spi_Ready == 1'b1)
                	begin
                		AdcState <= STATE_READ;
                    	Spi_ReadFlag <= 1'b0;
                	end
                end
            end
            
            STATE_READ:
            begin
            	Cs_Continueread <= 1'b0;
            	Spi_StartFlag <= 1'b1;
                Spi_Translength <= 32'd48;
                Spi_SendPackage[MAXLENGTH-1:MAXLENGTH-48] <= {`READCMD, `ADDRESS_DATA, 40'hffffffffff};
				AdcState <= STATE_WAITSPIOVER;
                JumpState <= STATE_READOVER;
            end
            
            STATE_READOVER:
            begin
                Spi_ReadFlag <= 1'b1;
                AdcState <= STATE_CRCSTART;
				o_result <= Spi_RecPackage[39:16];
                o_channel <= Spi_RecPackage[11:8];
				AdcCrc_Rst <= 1'b1;
                Cs_Continueread <= 1'b1;
				TestCnt <= TestCnt + 8'd1;
            end

			STATE_CRCSTART:
            begin
            	AdcCrc_Rst <= 1'b0;
				AdcCrc_Start <= 1'b1;
				AdcState <= STATE_CRCCAL;  
            end
            
            STATE_CRCCAL:
            begin
				AdcCrc_Start <= 1'b0;
				if(AdcCrcCnt < 8'd5)
                begin
                    AdcCrcCnt <= AdcCrcCnt + 1'b1;
                	AdcCrc_En <= 1'b1;
					case(AdcCrcCnt)
                    
                    	8'd0:	AdcCrc_Din <= 8'h44;
                    	8'd1:	AdcCrc_Din <= o_result[23:16];
                    	8'd2:	AdcCrc_Din <= o_result[15:8];
                    	8'd3:	AdcCrc_Din <= o_result[7:0];
                    	8'd4:	AdcCrc_Din <= Spi_RecPackage[15:8];
                    
                    endcase
                end
                else
                begin
                    AdcCrcCnt <= 8'd0;
					AdcCrc_En <= 1'b0;
					AdcCrc_End <= 1'b1;
                    AdcState <= STATE_CRCRESULT;
                end
            end

			STATE_CRCRESULT:
            begin
            	AdcCrc_End <= 1'b0;
            	if(AdcCrc_Vld == 1'b1)
                begin
                	if(AdcCrc_Out == Spi_RecPackage[7:0] && AdChannelRead[Spi_RecPackage[11:8]] == 1'b0)
                    begin
						AdChannelRead[Spi_RecPackage[11:8]] <= 1'b1;
						o_doneflag <= 1'b1;
                    end
					AdcState <= STATE_READSTART;     
                end
            end

			STATE_WAITSPIOVER:
            begin
                if(Spi_DoneFlag == 1'b1)
                begin
					Spi_StartFlag <= 1'b0;
                	AdcState <= JumpState;
                end
            end
            
        endcase
    end
end


SPI #
(
	.SYSCLKFREQ(SYSCLKFREQ),
	.UARTBAUD(UARTBAUD),
	.MAXLENGTH(MAXLENGTH),
    .MODE(3)
)
spi_trans
(
	.clk(clk)         				,  //system clk
    .rst_n(rst_n)       			,  //system reset
    
    .i_startflag(Spi_StartFlag)		,
    .o_doneflag(Spi_DoneFlag)		,
    .i_translength(Spi_Translength)	,
    .i_sendpackage(Spi_SendPackage)	,
    .o_recpackage(Spi_RecPackage)	,
    
    .spi_clk(o_spi_clk)				,
    .spi_cs(Cs_Spi)					,
    .spi_mosi(o_spi_mosi)			,
    .spi_miso(i_spi_miso)
);

AdcCrc8 adccrc
(
	.clk(clk),
	.din(AdcCrc_Din),
	.din_en(AdcCrc_En),
	.packet_end(AdcCrc_End),
	.packet_start(AdcCrc_Start),
	.rst(AdcCrc_Rst),
	.crc_out(AdcCrc_Out),
	.crc_out_vld(AdcCrc_Vld)
);

endmodule
