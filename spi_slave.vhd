library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_signed.all;

entity spi_slave is
	generic(
		msg_width : integer := 32);
	port(
		-- Common
		clk	: in std_logic; -- Source from 100 MHz pll output
		reset_n	: in std_logic; -- Sync reset

		busy	: out std_logic; -- High during data transfers

		-- Mode (unused as implemented cpol0 cpha0
		cpol	: in std_logic;
		cpha	: in std_logic;

		-- SPI signals (Connected to external pins)
		sclk	: in std_logic;
		ss_n	: in std_logic;
		mosi	: in std_logic; -- Master OUT Slave IN (OUR INPUT)
		miso	: out std_logic; -- Master IN slave OUT (OUR OUTPUT)
		
		
		-- Interfacing with watchdog, for passing along data
		rx_rdy	: out std_logic; -- We have data ready;
		rx_req	: in std_logic; -- Handshake for sending what we have received
		rx_data	: out std_logic_vector(msg_width-1 downto 0);
		tx_load_en : in std_logic;
		tx_load_data : in std_logic_vector(msg_width-1 downto 0)
	);
end entity spi_slave;

architecture behavioral of spi_slave is
	signal tx_buf : std_logic_vector(msg_width-1 downto 0) := X"00000000"; --X"5eadbeef";
	signal rx_buf : std_logic_vector(msg_width-1 downto 0) := (others => '0');

	type states is (IDLE,WAIT_POS_EDGE,SAMPLE,WAIT_NEG_EDGE,SHIFT_TX,UPDATE_MISO,END_MSG,ILLEGAL);
	signal curr_state : states := IDLE; -- Curr state we are in
	signal expt_state : states := IDLE;

	attribute fsm_encoding : string;
	attribute fsm_encoding of curr_state : signal is "one_hot";
	attribute fsm_encoding of expt_state : signal is "one_hot";


	-- Attributes because fuck optimizer taking my shit away
	attribute keep : string;
	attribute keep of tx_buf : signal is "true";
	attribute keep of rx_buf : signal is "true";
	attribute keep of curr_state : signal is "true";
	attribute keep of expt_state : signal is "true";
	attribute keep of error_trigger_r : signal is "true";
	
begin
	busy <= not ss_n;

	process(reset_n,clk)

	begin
		if(reset_n = '0') then
			curr_state <= IDLE; -- We are to go to idle after reset
			rx_buf <= (others => '0'); -- We havent received anything
			tx_buf <= X"00000000"; -- We dont have a message to send
			miso <= 'Z'; -- No data to send, high impendance
			rx_rdy <= '0';
		elsif(rising_edge(clk)) then
			case curr_state is
				when IDLE => -- IDLE, waits for transaction start
					-- ***********************************************************
					-- Wait for slave select to fall, which initiates transfer
					-- ***********************************************************
					fsm_error_line <= '0';
					if(ss_n = '0') then
						curr_state <= UPDATE_MISO;
						expt_state <= UPDATE_MISO;
					else
						curr_state <= IDLE;
						expt_state <= IDLE;
					end if;
        
                    if(rx_req = '1' and ss_n = '1') then
                        rx_rdy <= '0';
                    end if;
				
				    if(tx_load_en = '1' and ss_n = '1') then
				        tx_buf <= tx_load_data;
				    end if;
				    
				when WAIT_POS_EDGE => 
					-- ***********************************************************
					-- As per mode 0 (cpol0, cpha0) we sample on positive edges
					-- so we wait for it here
					-- ***********************************************************
                
					if(sclk = '1') then
						curr_state <= SAMPLE;
						expt_state <= SAMPLE;
					elsif(ss_n = '1') then
						curr_state <= END_MSG;
						expt_state <= END_MSG;
					else
						curr_state <= WAIT_POS_EDGE;
						expt_state <= WAIT_POS_EDGE;
					end if;
                    
				when WAIT_NEG_EDGE =>
					-- ***********************************************************
					-- On falling edges of sclk we are to update the data on the
					-- miso line
					--
					-- We also check if the amount of messages has been reached
					-- ***********************************************************
					if(sclk = '0') then
						curr_state <= SHIFT_TX;
						expt_state <= SHIFT_TX;
					else
						curr_state <= WAIT_NEG_EDGE;
						expt_state <= WAIT_NEG_EDGE;
					end if;
				    

	            
				when SHIFT_TX =>
					-- ***********************************************************
					-- Shift tx buffer so next bit is ready
					-- ***********************************************************
					tx_buf <= tx_buf(msg_width-2 downto 0) & tx_buf(msg_width-1);
					curr_state <= UPDATE_MISO;
					expt_state <= UPDATE_MISO;
					
				
				when UPDATE_MISO =>
					-- ***********************************************************
					-- Put next bit from tx buffer on miso line
					-- ***********************************************************
					miso <= tx_buf(msg_width-1);
					curr_state <= WAIT_POS_EDGE;
					expt_state <= WAIT_POS_EDGE;
	                

				when SAMPLE =>
					-- ***********************************************************
					-- Shift mosi into rx buffer
					-- ***********************************************************
					rx_buf <= rx_buf(msg_width-2 downto 0) & mosi;
					curr_state <= WAIT_NEG_EDGE;
					expt_state <= WAIT_NEG_EDGE;
                    
	            
				when END_MSG =>
					-- ***********************************************************
					--	Message complete, wait for rising edge of slave select
					-- ***********************************************************
					if(ss_n = '1') then
						curr_state <= IDLE;
						expt_state <= IDLE;
						--tx_buf <= rx_buf;
						rx_rdy <= '1';
						rx_data <= rx_buf;
					else
						curr_state <= END_MSG;
						expt_state <= END_MSG;
					end if;
				when ILLEGAL =>
					curr_state <= expt_state;

				when others =>

					curr_state <= expt_state;

			end case;
		end if;
	end process;
end behavioral;